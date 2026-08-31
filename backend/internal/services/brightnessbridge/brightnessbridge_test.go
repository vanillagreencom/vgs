package brightnessbridge

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeHelper(t *testing.T, script string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fake-helper")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// A helper stuck probing dead hardware cannot be joined: the kill that fires at
// the timeout does not land in uninterruptible sleep, and any grandchild keeps
// the stdout pipe open. The call must abandon the child and fail soft instead
// of blocking the backend request forever.
func TestCallAbandonsStuckHelper(t *testing.T) {
	// The backgrounded sleep inherits stdout and holds the pipe open long
	// after the parent is killed, reproducing the join-forever failure mode.
	helper := writeHelper(t, "#!/bin/sh\nsleep 60 &\nsleep 60\n")
	m := &Manager{helper: helper, timeout: 200 * time.Millisecond, waitDelay: 300 * time.Millisecond}

	type result struct {
		err error
	}
	done := make(chan result, 1)
	go func() {
		_, err := m.call("list", "--json")
		done <- result{err}
	}()

	select {
	case r := <-done:
		if r.err == nil {
			t.Fatal("expected timeout error, got nil")
		}
		if !strings.Contains(r.err.Error(), "timed out") {
			t.Fatalf("expected timed-out error, got: %v", r.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("call did not abandon the stuck helper: still blocked long past timeout+waitDelay")
	}
}

func TestCallReturnsHelperOutput(t *testing.T) {
	helper := writeHelper(t, "#!/bin/sh\necho '{\"devices\":[]}'\n")
	m := &Manager{helper: helper, timeout: timeout, waitDelay: waitDelay}
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
