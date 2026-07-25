package wlroutput

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os/exec"
	"time"

	"vshell/backend/internal/server"
)

const timeout = 5 * time.Second

type Manager struct {
	hyprctl string
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
	ID               int       `json:"id"`
	Name             string    `json:"name"`
	Description      string    `json:"description"`
	Make             string    `json:"make"`
	Model            string    `json:"model"`
	Serial           string    `json:"serial"`
	Width            int32     `json:"width"`
	Height           int32     `json:"height"`
	RefreshRate      float64   `json:"refreshRate"`
	X                int32     `json:"x"`
	Y                int32     `json:"y"`
	Scale            float64   `json:"scale"`
	Transform        int32     `json:"transform"`
	Disabled         bool     `json:"disabled"`
	AvailableModes   []string `json:"availableModes"`
	PhysicalWidth    int32    `json:"physicalWidth"`
	PhysicalHeight   int32    `json:"physicalHeight"`
	Vrr              bool     `json:"vrr"`
	CurrentFormat    string    `json:"currentFormat"`
	MirrorOf         string    `json:"mirrorOf"`
	Focused          bool      `json:"focused"`
	DPMSStatus       bool      `json:"dpmsStatus"`
	Solitary         string    `json:"solitary"`
	ActivelyTearing  bool      `json:"activelyTearing"`
	DirectScanoutTo  string    `json:"directScanoutTo"`
	CurrentWorkspace any       `json:"activeWorkspace"`
	SpecialWorkspace any       `json:"specialWorkspace"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	hyprctl, err := exec.LookPath("hyprctl")
	if err != nil {
		return nil, fmt.Errorf("hyprctl not found")
	}
	m := &Manager{hyprctl: hyprctl}
	srv.Register("wlroutput", "wlroutput.getState", m.handleGetState)
	srv.Register("wlroutput", "wlroutput.subscribe", m.handleGetState)
	srv.Register("wlroutput", "wlroutput.applyConfiguration", rejectWrite)
	srv.Register("wlroutput", "wlroutput.testConfiguration", rejectWrite)
	srv.RegisterSnapshot("wlroutput", func() any {
		state, err := m.state()
		if err != nil {
			return map[string]any{"outputs": []any{}, "serial": 0, "backend": "hyprctl", "error": err.Error()}
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
	return nil, fmt.Errorf("wlroutput configuration writes are disabled; VGS display config owns Hyprland layout")
}

func (m *Manager) state() (State, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	// "monitors all" includes disabled outputs; plain "monitors" hides them,
	// which would make a disabled monitor impossible to show or re-enable.
	cmd := exec.CommandContext(ctx, m.hyprctl, "monitors", "all", "-j")
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

func boolUint(v bool) uint32 {
	if v {
		return 1
	}
	return 0
}
