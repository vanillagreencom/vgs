package wlroutput

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"vshell/backend/internal/refresh"
)

func fakeOutputCommand(t *testing.T, directory, name string) string {
	t.Helper()
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestCompositorCommandForSelection(t *testing.T) {
	directory := t.TempDir()
	niri := fakeOutputCommand(t, directory, "niri")
	hyprctl := fakeOutputCommand(t, directory, "hyprctl")
	t.Setenv("PATH", directory)

	command, backend, err := compositorCommandFor("niri")
	if err != nil || command != niri || backend != "niri" {
		t.Fatalf("Niri command = (%q, %q, %v)", command, backend, err)
	}
	command, backend, err = compositorCommandFor("hyprland")
	if err != nil || command != hyprctl || backend != "hyprctl" {
		t.Fatalf("Hyprland command = (%q, %q, %v)", command, backend, err)
	}
}

func TestNiriState(t *testing.T) {
	dir := t.TempDir()
	command := filepath.Join(dir, "niri")
	payload := `{"DP-1":{"name":"DP-1","make":"Acme","model":"Panel","serial":"123","physical_size":[600,340],"modes":[{"width":2560,"height":1440,"refresh_rate":144000,"is_preferred":true}],"current_mode":0,"vrr_supported":true,"vrr_enabled":true,"logical":{"x":20,"y":30,"width":1280,"height":720,"scale":2.0,"transform":"90"}}}`
	script := "#!/bin/sh\nprintf '%s' '" + payload + "'\n"
	if err := os.WriteFile(command, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	state, err := newManager(noBroadcast{}, command, "niri", nil).state.Query()
	if err != nil {
		t.Fatal(err)
	}
	if state.Backend != "niri" || len(state.Outputs) != 1 {
		t.Fatalf("unexpected state: %#v", state)
	}
	output := state.Outputs[0]
	if output.Name != "DP-1" || !output.Enabled || output.Scale != 2 || output.Transform != 1 {
		t.Fatalf("unexpected output: %#v", output)
	}
	if output.CurrentMode == nil || output.CurrentMode.Refresh != 144000 || output.AdaptiveSync != 1 {
		t.Fatalf("unexpected mode: %#v", output)
	}
}

func TestNiriDisabledOutput(t *testing.T) {
	dir := t.TempDir()
	command := filepath.Join(dir, "niri")
	if err := os.WriteFile(command, []byte("#!/bin/sh\nprintf '%s' '{\"HDMI-A-1\":{\"name\":\"HDMI-A-1\",\"modes\":[],\"current_mode\":null,\"logical\":null}}'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	state, err := newManager(noBroadcast{}, command, "niri", nil).state.Query()
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Outputs) != 1 || state.Outputs[0].Enabled || state.Outputs[0].CurrentMode != nil {
		t.Fatalf("disabled output was not preserved: %#v", state.Outputs)
	}
}

type noBroadcast struct{}

func (noBroadcast) Broadcast(string, any) {}

func stubManager(t *testing.T, query func() (State, error)) *Manager {
	t.Helper()
	m := newManager(noBroadcast{}, "", "stub", nil)
	m.query = query
	m.state = refresh.NewService(noBroadcast{}, nil, "wlroutput", 0, func() (State, error) { return m.query() })
	return m
}

// Before the first query there is nothing to report. An empty output list would
// reach the shell as "no monitors" and blank the display settings page while
// hyprctl has never run.
func TestCachedStateBeforeFirstQueryReportsNothing(t *testing.T) {
	m := stubManager(t, func() (State, error) { return State{}, errStubQuery })
	if got := m.state.Cached(); got != nil {
		t.Fatalf("cached state before the first query = %v, want nothing to send", got)
	}
	if _, err := m.handleGetState(nil); err == nil {
		t.Fatal("handleGetState returned no error for a failing query")
	}
	if got := m.state.Cached(); got != nil {
		t.Fatalf("a failed query cached %v; an empty layout must not become truth", got)
	}
}

// A getState call warms what the next subscribe serves.
func TestGetStateWarmsTheRegisteredSource(t *testing.T) {
	m := stubManager(t, func() (State, error) {
		return State{Outputs: []Output{{Name: "DP-1"}}, Serial: 4, Backend: "stub"}, nil
	})
	if _, err := m.handleGetState(nil); err != nil {
		t.Fatalf("handleGetState: %v", err)
	}
	got, ok := m.state.Cached().(State)
	if !ok {
		t.Fatalf("cached value is %T, want State", m.state.Cached())
	}
	if len(got.Outputs) != 1 || got.Outputs[0].Name != "DP-1" {
		t.Fatalf("cached outputs = %v, want the query result", got.Outputs)
	}
}

var errStubQuery = errors.New("compositor unreachable")
