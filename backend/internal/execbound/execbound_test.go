package execbound

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestCommandSetsDefaultWaitDelay(t *testing.T) {
	cmd := Command(context.Background(), "true")
	if cmd.WaitDelay != DefaultWaitDelay {
		t.Fatalf("WaitDelay = %v, want %v", cmd.WaitDelay, DefaultWaitDelay)
	}
}

// writePipeHolder writes a script whose backgrounded child inherits stdout and
// holds the pipe open after the script itself is gone. Without WaitDelay,
// Output reads that pipe toward an EOF that never comes and these tests hang
// until the go test timeout.
func writePipeHolder(t *testing.T, tail string) string {
	t.Helper()
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	script := "#!/bin/sh\nsleep 60 &\necho $! > " + pidFile + "\n" + tail
	path := filepath.Join(dir, "pipe-holder")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { killRecorded(pidFile) })
	return path
}

// The wedge this package exists to prevent: the context deadline kills the
// child, the descendant keeps the pipe, and Output must still return.
func TestCommandReturnsAfterDeadlineKill(t *testing.T) {
	path := writePipeHolder(t, "exec sleep 60\n")
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := Command(ctx, path).Output()
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("Output succeeded; want the killed child's error")
	}
	if want := 200*time.Millisecond + DefaultWaitDelay + 2*time.Second; elapsed > want {
		t.Fatalf("Output took %v, want under %v", elapsed, want)
	}
}

// The child exits cleanly and only the descendant holds the pipe, so no
// deadline is involved: WaitDelay alone ends the read, and what the child
// wrote is still returned for the caller to salvage.
func TestCommandReturnsAfterCleanExitWithHeldPipe(t *testing.T) {
	path := writePipeHolder(t, "echo done\n")
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	out, err := Command(ctx, path).Output()

	if !errors.Is(err, exec.ErrWaitDelay) {
		t.Fatalf("err = %v, want exec.ErrWaitDelay", err)
	}
	if strings.TrimSpace(string(out)) != "done" {
		t.Fatalf("out = %q, want %q", out, "done")
	}
}

func killRecorded(pidFile string) {
	b, err := os.ReadFile(pidFile)
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || pid <= 1 {
		return
	}
	_ = syscall.Kill(pid, syscall.SIGKILL)
}
