package brightnessbridge

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// writePipeHolderHelper writes a fake helper whose backgrounded child inherits
// stdout and holds the pipe open long after the helper is gone, reproducing
// how a ddcutil wedged on a dead bus keeps the pipes of a killed or exited
// helper alive. `body` runs after the child is spawned; the child's PID is
// killed from t.Cleanup so no stray sleep outlives the test.
func writePipeHolderHelper(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	script := "#!/bin/sh\nsleep 60 &\necho $! > " + pidFile + "\n" + body
	path := filepath.Join(dir, "fake-helper")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		b, err := os.ReadFile(pidFile)
		if err != nil {
			return
		}
		pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
		if err != nil || pid <= 1 {
			return
		}
		_ = syscall.Kill(pid, syscall.SIGKILL)
	})
	return path
}

// A helper that never finishes must be killed at the timeout and its
// pipe-holding descendant abandoned; the call fails soft instead of blocking
// the backend request until the descendant exits.
func TestCallAbandonsStuckHelper(t *testing.T) {
	// exec replaces the shell so the timeout's kill leaves only the
	// backgrounded pipe holder behind.
	helper := writePipeHolderHelper(t, "exec sleep 60\n")
	m := &Manager{helper: helper, timeout: 200 * time.Millisecond, waitDelay: 300 * time.Millisecond}

	done := make(chan error, 1)
	go func() {
		_, err := m.call("list", "--json")
		done <- err
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected timeout error, got nil")
		}
		if !strings.Contains(err.Error(), "timed out") {
			t.Fatalf("expected timed-out error, got: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("call did not abandon the stuck helper: still blocked long past timeout+waitDelay")
	}
}

// A helper that exits promptly with a complete response must not have that
// response discarded just because a descendant held the pipes past waitDelay.
func TestCallSalvagesOutputFromHeldPipes(t *testing.T) {
	helper := writePipeHolderHelper(t, "echo '{\"devices\":[]}'\nexit 0\n")
	m := &Manager{helper: helper, timeout: 5 * time.Second, waitDelay: 300 * time.Millisecond}

	done := make(chan struct {
		res any
		err error
	}, 1)
	go func() {
		res, err := m.call("list", "--json")
		done <- struct {
			res any
			err error
		}{res, err}
	}()

	select {
	case r := <-done:
		if r.err != nil {
			t.Fatalf("expected salvaged response, got error: %v", r.err)
		}
		obj, ok := r.res.(map[string]any)
		if !ok {
			t.Fatalf("expected decoded JSON object, got %T", r.res)
		}
		if _, ok := obj["devices"]; !ok {
			t.Fatalf("expected devices key in %v", obj)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("call still blocked long past waitDelay on pipes held by a descendant")
	}
}

func TestCallReturnsHelperOutput(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fake-helper")
	if err := os.WriteFile(path, []byte("#!/bin/sh\necho '{\"devices\":[]}'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	m := &Manager{helper: path, timeout: timeout, waitDelay: waitDelay}
	res, err := m.call("list", "--json")
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
	obj, ok := res.(map[string]any)
	if !ok {
		t.Fatalf("expected decoded JSON object, got %T", res)
	}
	if _, ok := obj["devices"]; !ok {
		t.Fatalf("expected devices key in %v", obj)
	}
}
