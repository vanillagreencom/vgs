package gamma

import (
	"os"
	"path/filepath"
	"testing"
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
