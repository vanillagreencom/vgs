package brightnessbridge

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"vshell/backend/internal/refresh"
)

// writePipeHolderHelper starts a fake helper with a descendant that retains
// stdout. This exercises the WaitDelay bound even though helper probes normally
// use separate pipes. Cleanup kills the recorded child PID.
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

// The fixture gives the blocked helper no descendant with backend pipes, so the
// context deadline can end the read without waiting for WaitDelay.
func TestCallTimeoutReleasesIsolatedHelper(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fake-helper")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexec sleep 60\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	m := &Manager{helper: path, timeout: 200 * time.Millisecond, waitDelay: 5 * time.Second}

	start := time.Now()
	_, err := m.call("list", "--json")
	elapsed := time.Since(start)
	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("expected timed-out error, got: %v", err)
	}
	if elapsed >= 2*time.Second {
		t.Fatalf("call took %v; an isolated helper resolves at the context deadline, not WaitDelay", elapsed)
	}
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
// response discarded because a descendant held the pipes past waitDelay. The
// second row is the boundary where the deadline also expires during that wait:
// exec.ErrWaitDelay and a DeadlineExceeded context are both true, and the
// salvage must still win over the timeout classification.
func TestCallSalvagesOutputFromHeldPipes(t *testing.T) {
	cases := []struct {
		name      string
		timeout   time.Duration
		waitDelay time.Duration
	}{
		{"deadline far off", 5 * time.Second, 300 * time.Millisecond},
		{"deadline expires during the held-pipe wait", 300 * time.Millisecond, 700 * time.Millisecond},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			helper := writePipeHolderHelper(t, "echo '{\"devices\":[]}'\nexit 0\n")
			m := &Manager{helper: helper, timeout: tc.timeout, waitDelay: tc.waitDelay}

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
				t.Fatal("call still blocked long past timeout and waitDelay on pipes held by a descendant")
			}
		})
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

type noBroadcast struct{}

func (noBroadcast) Broadcast(string, any) {}

func newStubManager(sweep func() (any, error)) *Manager {
	m := &Manager{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	m.state = refresh.NewService(noBroadcast{}, m.log, "brightness", 0, sweep)
	return m
}

// Before the first helper run there is nothing to report. An empty device list
// would reach the shell as "no backlights" and hide the brightness control,
// and this helper is the slowest query the daemon owns.
func TestCachedStateBeforeFirstHelperRunReportsNothing(t *testing.T) {
	m := newStubManager(func() (any, error) { return nil, errors.New("helper unavailable") })
	if got := m.state.Cached(); got != nil {
		t.Fatalf("cached state before the first helper run = %v, want nothing to send", got)
	}
}

// A getState call warms what the next subscribe serves.
func TestGetStateWarmsTheRegisteredSource(t *testing.T) {
	want := map[string]any{"devices": []any{"backlight"}}
	m := newStubManager(func() (any, error) { return want, nil })
	if _, err := m.handleGetState(nil); err != nil {
		t.Fatalf("handleGetState: %v", err)
	}
	got, ok := m.state.Cached().(map[string]any)
	if !ok {
		t.Fatalf("cached value is %T, want a map", m.state.Cached())
	}
	if devices := got["devices"].([]any); len(devices) != 1 {
		t.Fatalf("cached devices = %v, want the recorded helper run", devices)
	}
}

// The keep-latest slot is keyed by this value, so a write to one display must
// never share a key with a write to another.
func TestDeviceKeySeparatesDisplays(t *testing.T) {
	rows := []struct {
		name   string
		params string
		want   string
	}{
		{"named display", `{"device":"eDP-1","percent":40}`, "eDP-1"},
		{"another display", `{"device":"DP-2","percent":40}`, "DP-2"},
		{"same display, another value", `{"device":"eDP-1","percent":90}`, "eDP-1"},
		{"no device", `{"percent":40}`, ""},
		{"malformed params", `not json`, ""},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			if got := deviceKey(json.RawMessage(row.params)); got != row.want {
				t.Fatalf("deviceKey(%s) = %q, want %q", row.params, got, row.want)
			}
		})
	}
}
