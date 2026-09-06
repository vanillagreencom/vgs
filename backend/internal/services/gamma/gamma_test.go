package gamma

import (
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"vshell/backend/internal/server"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func fakeCommand(t *testing.T, directory, name string) string {
	t.Helper()
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestGammaCommandForCompositor(t *testing.T) {
	directory := t.TempDir()
	wlsunset := fakeCommand(t, directory, "wlsunset")
	hyprsunset := fakeCommand(t, directory, "hyprsunset")
	hyprctl := fakeCommand(t, directory, "hyprctl")
	t.Setenv("PATH", directory)

	binary, control, backend, err := gammaCommandFor("niri")
	if err != nil || binary != wlsunset || control != "" || backend != "wlsunset" {
		t.Fatalf("Niri command = (%q, %q, %q, %v)", binary, control, backend, err)
	}
	binary, control, backend, err = gammaCommandFor("hyprland")
	if err != nil || binary != hyprsunset || control != hyprctl || backend != "hyprsunset" {
		t.Fatalf("Hyprland command = (%q, %q, %q, %v)", binary, control, backend, err)
	}
}

func TestWlsunsetSkipsIdenticalProcessReplacement(t *testing.T) {
	directory := t.TempDir()
	binary := filepath.Join(directory, "wlsunset")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\nexec /usr/bin/sleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	manager := &Manager{binary: binary, backend: "wlsunset"}
	state := State{
		Config:      Config{Enabled: true, Gamma: 0.9},
		CurrentTemp: 4200,
	}

	manager.mu.Lock()
	if err := manager.applyGammaLocked(state); err != nil {
		manager.mu.Unlock()
		t.Fatal(err)
	}
	first := manager.cmd
	if err := manager.applyGammaLocked(state); err != nil {
		manager.mu.Unlock()
		t.Fatal(err)
	}
	if manager.cmd != first {
		manager.mu.Unlock()
		t.Fatal("identical effective state replaced wlsunset")
	}
	state.CurrentTemp = 4300
	if err := manager.applyGammaLocked(state); err != nil {
		manager.mu.Unlock()
		t.Fatal(err)
	}
	if manager.cmd == first {
		manager.mu.Unlock()
		t.Fatal("changed effective temperature did not replace wlsunset")
	}
	manager.stopLocked()
	manager.mu.Unlock()
}

func TestHyprsunsetIPCTimesOutEachAttempt(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "hyprctl.log")
	hyprctl := filepath.Join(dir, "hyprctl")
	if err := os.WriteFile(hyprctl, []byte("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$HYPRCTL_LOG\"\nexec sleep 60\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HYPRCTL_LOG", logPath)
	manager := &Manager{hyprctl: hyprctl}

	started := time.Now()
	err := manager.hyprsunsetIPCWithBounds(20*time.Millisecond, time.Millisecond, "temperature", "4200")
	elapsed := time.Since(started)

	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("hyprsunsetIPCWithBounds error = %v, want timeout", err)
	}
	if elapsed > 2*time.Second {
		t.Fatalf("hyprsunsetIPCWithBounds took %v, want each retry attempt bounded", elapsed)
	}
	content, readErr := os.ReadFile(logPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if attempts := strings.Count(string(content), "\n"); attempts != hyprsunsetIPCAttempts {
		t.Fatalf("attempts = %d, want %d", attempts, hyprsunsetIPCAttempts)
	}
}

func TestHandleSetGammaFailsWhenGammaIPCTimesOut(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "hyprctl.log")
	hyprctl := filepath.Join(dir, "hyprctl")
	body := `printf '%s\n' "$*" >> "$HYPRCTL_LOG"
case "$*" in
"hyprsunset gamma "*) exec sleep 1 ;;
"hyprsunset temperature "*) exit 0 ;;
*) exit 2 ;;
esac
`
	if err := os.WriteFile(hyprctl, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HYPRCTL_LOG", logPath)
	cfg := defaultConfig()
	cfg.Enabled = true
	manager := &Manager{
		log:     discardLogger(),
		srv:     server.New(uint32(os.Getuid()), discardLogger()),
		backend: "hyprsunset",
		hyprctl: hyprctl,
		cmd:     &exec.Cmd{},
		state:   State{Config: cfg},
	}

	started := time.Now()
	_, err := manager.handleSetGamma(json.RawMessage(`{"gamma":0.8}`))
	elapsed := time.Since(started)

	if err == nil {
		t.Fatal("handleSetGamma error = nil, want gamma timeout")
	}
	// This is the one path that runs the production attempt count, attempt
	// timeout and retry delay; their product must stay inside a UI-tolerable
	// wait, so a change to any of them shows up here.
	if elapsed > 10*time.Second {
		t.Fatalf("handleSetGamma took %v, want every retry inside 10s", elapsed)
	}
	if !strings.Contains(err.Error(), "set hyprsunset gamma") || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("handleSetGamma error = %v, want gamma timeout", err)
	}
	content, readErr := os.ReadFile(logPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if !strings.Contains(string(content), "hyprsunset gamma 80") {
		t.Fatalf("hyprctl log = %q, want gamma IPC attempts", content)
	}
	if strings.Contains(string(content), "temperature") {
		t.Fatalf("hyprctl log = %q, want no temperature IPC after gamma failure", content)
	}
}
