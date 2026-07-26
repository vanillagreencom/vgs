package wlroutput

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os/exec"
	"sort"
	"strings"
	"time"

	"vshell/backend/internal/compositor"
	"vshell/backend/internal/server"
)

const timeout = 5 * time.Second

type Manager struct {
	command string
	backend string
}

type State struct {
	Outputs []Output `json:"outputs"`
	Serial  uint32   `json:"serial"`
	Backend string   `json:"backend"`
}

type Output struct {
	Name                  string       `json:"name"`
	Description           string       `json:"description"`
	Make                  string       `json:"make"`
	Model                 string       `json:"model"`
	SerialNumber          string       `json:"serialNumber"`
	PhysicalWidth         int32        `json:"physicalWidth"`
	PhysicalHeight        int32        `json:"physicalHeight"`
	Enabled               bool         `json:"enabled"`
	X                     int32        `json:"x"`
	Y                     int32        `json:"y"`
	Transform             int32        `json:"transform"`
	Scale                 float64      `json:"scale"`
	CurrentMode           *OutputMode  `json:"currentMode,omitempty"`
	Modes                 []OutputMode `json:"modes"`
	AdaptiveSync          uint32       `json:"adaptiveSync"`
	AdaptiveSyncSupported bool         `json:"adaptiveSyncSupported"`
	ID                    uint32       `json:"id"`
}

type OutputMode struct {
	Width     int32  `json:"width"`
	Height    int32  `json:"height"`
	Refresh   int32  `json:"refresh"`
	Preferred bool   `json:"preferred"`
	ID        uint32 `json:"id"`
}

type hyprMonitor struct {
	ID               int      `json:"id"`
	Name             string   `json:"name"`
	Description      string   `json:"description"`
	Make             string   `json:"make"`
	Model            string   `json:"model"`
	Serial           string   `json:"serial"`
	Width            int32    `json:"width"`
	Height           int32    `json:"height"`
	RefreshRate      float64  `json:"refreshRate"`
	X                int32    `json:"x"`
	Y                int32    `json:"y"`
	Scale            float64  `json:"scale"`
	Transform        int32    `json:"transform"`
	Disabled         bool     `json:"disabled"`
	AvailableModes   []string `json:"availableModes"`
	PhysicalWidth    int32    `json:"physicalWidth"`
	PhysicalHeight   int32    `json:"physicalHeight"`
	Vrr              bool     `json:"vrr"`
	CurrentFormat    string   `json:"currentFormat"`
	MirrorOf         string   `json:"mirrorOf"`
	Focused          bool     `json:"focused"`
	DPMSStatus       bool     `json:"dpmsStatus"`
	Solitary         string   `json:"solitary"`
	ActivelyTearing  bool     `json:"activelyTearing"`
	DirectScanoutTo  string   `json:"directScanoutTo"`
	CurrentWorkspace any      `json:"activeWorkspace"`
	SpecialWorkspace any      `json:"specialWorkspace"`
}

type niriOutput struct {
	Name         string       `json:"name"`
	Make         string       `json:"make"`
	Model        string       `json:"model"`
	Serial       *string      `json:"serial"`
	PhysicalSize []int32      `json:"physical_size"`
	Modes        []niriMode   `json:"modes"`
	CurrentMode  *int         `json:"current_mode"`
	VRRSupported bool         `json:"vrr_supported"`
	VRREnabled   bool         `json:"vrr_enabled"`
	Logical      *niriLogical `json:"logical"`
}

type niriMode struct {
	Width       int32 `json:"width"`
	Height      int32 `json:"height"`
	RefreshRate int32 `json:"refresh_rate"`
	IsPreferred bool  `json:"is_preferred"`
}

type niriLogical struct {
	X         int32   `json:"x"`
	Y         int32   `json:"y"`
	Scale     float64 `json:"scale"`
	Transform string  `json:"transform"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	command, backend, err := compositorCommand()
	if err != nil {
		return nil, err
	}
	m := &Manager{command: command, backend: backend}
	srv.Register("wlroutput", "wlroutput.getState", m.handleGetState)
	srv.Register("wlroutput", "wlroutput.subscribe", m.handleGetState)
	srv.Register("wlroutput", "wlroutput.applyConfiguration", rejectWrite)
	srv.Register("wlroutput", "wlroutput.testConfiguration", rejectWrite)
	srv.RegisterSnapshot("wlroutput", func() any {
		state, err := m.state()
		if err != nil {
			return map[string]any{"outputs": []any{}, "serial": 0, "backend": backend, "error": err.Error()}
		}
		return state
	})
	return m, nil
}

func (m *Manager) Close() {}

func (m *Manager) handleGetState(json.RawMessage) (any, error) {
	return m.state()
}

func rejectWrite(json.RawMessage) (any, error) {
	return nil, fmt.Errorf("wlroutput configuration writes are disabled; VGS display config owns compositor layout")
}

func (m *Manager) state() (State, error) {
	if m.backend == "niri" {
		return m.niriState()
	}
	return m.hyprlandState()
}

func (m *Manager) hyprlandState() (State, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	// "monitors all" includes disabled outputs; plain "monitors" hides them,
	// which would make a disabled monitor impossible to show or re-enable.
	cmd := exec.CommandContext(ctx, m.command, "monitors", "all", "-j")
	out, err := cmd.Output()
	if ctx.Err() == context.DeadlineExceeded {
		return State{}, fmt.Errorf("hyprctl monitors timed out")
	}
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			return State{}, fmt.Errorf("%s", ee.Stderr)
		}
		return State{}, err
	}
	var monitors []hyprMonitor
	if err := json.Unmarshal(out, &monitors); err != nil {
		return State{}, fmt.Errorf("decode hyprctl monitors: %w", err)
	}
	outputs := make([]Output, 0, len(monitors))
	for _, mon := range monitors {
		id := uint32(0)
		if mon.ID > 0 {
			id = uint32(mon.ID)
		}
		mode := OutputMode{
			Width:     mon.Width,
			Height:    mon.Height,
			Refresh:   int32(mon.RefreshRate * 1000),
			Preferred: true,
			ID:        id,
		}
		outputs = append(outputs, Output{
			Name:                  mon.Name,
			Description:           mon.Description,
			Make:                  mon.Make,
			Model:                 mon.Model,
			SerialNumber:          mon.Serial,
			PhysicalWidth:         mon.PhysicalWidth,
			PhysicalHeight:        mon.PhysicalHeight,
			Enabled:               !mon.Disabled,
			X:                     mon.X,
			Y:                     mon.Y,
			Transform:             mon.Transform,
			Scale:                 mon.Scale,
			CurrentMode:           &mode,
			Modes:                 []OutputMode{mode},
			AdaptiveSync:          boolUint(mon.Vrr),
			AdaptiveSyncSupported: true,
			ID:                    id,
		})
	}
	return State{Outputs: outputs, Serial: uint32(time.Now().Unix()), Backend: "hyprctl"}, nil
}

func (m *Manager) niriState() (State, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, m.command, "msg", "-j", "outputs")
	out, err := cmd.Output()
	if ctx.Err() == context.DeadlineExceeded {
		return State{}, fmt.Errorf("niri outputs timed out")
	}
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			return State{}, fmt.Errorf("%s", strings.TrimSpace(string(ee.Stderr)))
		}
		return State{}, err
	}
	var raw map[string]niriOutput
	if err := json.Unmarshal(out, &raw); err != nil {
		return State{}, fmt.Errorf("decode niri outputs: %w", err)
	}
	names := make([]string, 0, len(raw))
	for name := range raw {
		names = append(names, name)
	}
	sort.Strings(names)
	outputs := make([]Output, 0, len(names))
	for index, name := range names {
		item := raw[name]
		id := uint32(index + 1)
		modes := make([]OutputMode, 0, len(item.Modes))
		for modeIndex, mode := range item.Modes {
			modes = append(modes, OutputMode{
				Width: mode.Width, Height: mode.Height, Refresh: mode.RefreshRate,
				Preferred: mode.IsPreferred, ID: uint32(modeIndex + 1),
			})
		}
		var current *OutputMode
		if item.CurrentMode != nil && *item.CurrentMode >= 0 && *item.CurrentMode < len(modes) {
			mode := modes[*item.CurrentMode]
			current = &mode
		}
		output := Output{
			Name: item.Name, Description: strings.TrimSpace(item.Make + " " + item.Model),
			Make: item.Make, Model: item.Model, Enabled: item.Logical != nil,
			Scale: 1, CurrentMode: current, Modes: modes,
			AdaptiveSync: boolUint(item.VRREnabled), AdaptiveSyncSupported: item.VRRSupported, ID: id,
		}
		if item.Serial != nil {
			output.SerialNumber = *item.Serial
		}
		if len(item.PhysicalSize) >= 2 {
			output.PhysicalWidth, output.PhysicalHeight = item.PhysicalSize[0], item.PhysicalSize[1]
		}
		if item.Logical != nil {
			output.X, output.Y = item.Logical.X, item.Logical.Y
			output.Scale = item.Logical.Scale
			output.Transform = niriTransform(item.Logical.Transform)
		}
		outputs = append(outputs, output)
	}
	return State{Outputs: outputs, Serial: uint32(time.Now().Unix()), Backend: "niri"}, nil
}

func compositorCommand() (string, string, error) {
	return compositorCommandFor(compositor.Current())
}

func compositorCommandFor(current string) (string, string, error) {
	if current == "niri" {
		if command, err := exec.LookPath("niri"); err == nil {
			return command, "niri", nil
		}
	}
	if command, err := exec.LookPath("hyprctl"); err == nil {
		return command, "hyprctl", nil
	}
	if command, err := exec.LookPath("niri"); err == nil {
		return command, "niri", nil
	}
	return "", "", fmt.Errorf("neither hyprctl nor niri found")
}

func niriTransform(value string) int32 {
	transforms := map[string]int32{
		"Normal": 0, "90": 1, "180": 2, "270": 3,
		"Flipped": 4, "Flipped90": 5, "Flipped180": 6, "Flipped270": 7,
	}
	return transforms[value]
}

func boolUint(v bool) uint32 {
	if v {
		return 1
	}
	return 0
}
