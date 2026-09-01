package gamma

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

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
