package execbound

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

// childFixture writes a shell script that records pids in a file the cleanup
// reaps by pid, and returns the script and pid file paths.
func childFixture(t *testing.T, body string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	pidPath := filepath.Join(dir, "fixture.pids")
	path := filepath.Join(dir, "child")
	script := fmt.Sprintf("#!/bin/sh\nPIDS='%s'\n%s", pidPath, body)
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	reapFixture(t, pidPath)
	return path, pidPath
}

// awaitPIDs waits until the fixture has recorded want pids.
func awaitPIDs(t *testing.T, path string, want int) []int {
	t.Helper()
	deadline := time.Now().Add(maxBoundedElapsed)
	for time.Now().Before(deadline) {
		if pids, err := fixturePIDs(path); err == nil && len(pids) >= want {
			return pids
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("fixture did not record %d pid(s) in %s", want, path)
	return nil
}

func awaitAllGone(t *testing.T, what string, pids []int) {
	t.Helper()
	for _, pid := range pids {
		if err := awaitGone(pid, maxBoundedElapsed); err != nil {
			t.Fatalf("%s: pid %d: %v", what, pid, err)
		}
	}
}

func awaitDone(t *testing.T, c *Child) {
	t.Helper()
	select {
	case <-c.Done():
	case <-time.After(maxBoundedElapsed + ChildStopGrace):
		t.Fatal("child was not reaped")
	}
}

func TestChildStopEndsItsProcessGroup(t *testing.T) {
	script, pids := childFixture(t, "echo $$ >> \"$PIDS\"\nsleep 60 &\necho $! >> \"$PIDS\"\nwait\n")
	child, err := StartChild(context.Background(), ChildOptions{}, script)
	if err != nil {
		t.Fatal(err)
	}
	recorded := awaitPIDs(t, pids, 2)

	child.Stop()

	awaitAllGone(t, "Stop", recorded)
}

func TestChildStopKillsAGroupThatIgnoresTerm(t *testing.T) {
	script, pids := childFixture(t, "trap '' TERM\necho $$ >> \"$PIDS\"\nwhile :; do sleep 1; done\n")
	child, err := StartChild(context.Background(), ChildOptions{}, script)
	if err != nil {
		t.Fatal(err)
	}
	recorded := awaitPIDs(t, pids, 1)

	stopped := make(chan struct{})
	go func() {
		child.Stop()
		close(stopped)
	}()
	select {
	case <-stopped:
	case <-time.After(ChildStopGrace + maxBoundedElapsed):
		t.Fatal("Stop did not return for a child that ignores SIGTERM")
	}
	awaitAllGone(t, "Stop after SIGKILL", recorded)
}

func TestChildLeaderExitEndsWhatIsLeftOfItsGroup(t *testing.T) {
	script, pids := childFixture(t, "sleep 60 &\necho $! >> \"$PIDS\"\nexit 0\n")
	child, err := StartChild(context.Background(), ChildOptions{}, script)
	if err != nil {
		t.Fatal(err)
	}
	awaitDone(t, child)

	awaitAllGone(t, "leader exit", awaitPIDs(t, pids, 1))
}

func TestChildStopsWhenItsContextEnds(t *testing.T) {
	script, pids := childFixture(t, "echo $$ >> \"$PIDS\"\necho ready\nexec sleep 60\n")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	child, err := StartChild(ctx, ChildOptions{Stdout: true}, script)
	if err != nil {
		t.Fatal(err)
	}
	stdout := child.Stdout()
	defer stdout.Close()
	lines := bufio.NewScanner(stdout)
	if !lines.Scan() || lines.Text() != "ready" {
		t.Fatalf("first stdout line = %q, want %q", lines.Text(), "ready")
	}

	cancel()

	awaitDone(t, child)
	if lines.Scan() {
		t.Fatalf("stdout carried %q after the child stopped; want EOF", lines.Text())
	}
	awaitAllGone(t, "context end", awaitPIDs(t, pids, 1))
}

const childParentEnv = "EXECBOUND_CHILD_PARENT_PIDS"

// TestChildDiesWithItsParent runs a parent process that starts a child and
// exits without stopping it, the way a panicking or killed backend does.
func TestChildDiesWithItsParent(t *testing.T) {
	if path := os.Getenv(childParentEnv); path != "" {
		runChildParent(path)
		return
	}
	sleep, err := exec.LookPath("sleep")
	if err != nil {
		t.Skip("sleep not found")
	}
	pids := filepath.Join(t.TempDir(), "fixture.pids")
	reapFixture(t, pids)
	parent := exec.Command(os.Args[0], "-test.run=^TestChildDiesWithItsParent$")
	parent.Env = []string{childParentEnv + "=" + pids, "PATH=" + filepath.Dir(sleep)}
	if out, err := parent.CombinedOutput(); err != nil {
		t.Fatalf("parent process failed: %v\n%s", err, out)
	}

	awaitAllGone(t, "parent exit", awaitPIDs(t, pids, 1))
}

// runChildParent starts a child that records its own pid and exits once the
// record exists, so the child is known to be running when its parent dies.
func runChildParent(path string) {
	_, err := StartChild(context.Background(), ChildOptions{}, "/bin/sh", "-c", `echo $$ > "$0"; exec sleep 60`, path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "child parent:", err)
		os.Exit(1)
	}
	deadline := time.Now().Add(maxBoundedElapsed)
	for time.Now().Before(deadline) {
		if pids, err := fixturePIDs(path); err == nil && len(pids) == 1 {
			os.Exit(0)
		}
		time.Sleep(10 * time.Millisecond)
	}
	fmt.Fprintln(os.Stderr, "child parent: the child never recorded its pid")
	os.Exit(1)
}

func TestChildStartFailureReturnsTheError(t *testing.T) {
	_, err := StartChild(context.Background(), ChildOptions{Stdout: true}, filepath.Join(t.TempDir(), "missing"))
	if !errors.Is(err, os.ErrNotExist) && !errors.Is(err, syscall.ENOENT) {
		t.Fatalf("StartChild error = %v, want not-exist", err)
	}
}
