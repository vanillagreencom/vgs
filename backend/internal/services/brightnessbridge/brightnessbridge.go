package brightnessbridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"strconv"
	"time"

	"vshell/backend/internal/execbound"
	"vshell/backend/internal/helperbin"
	"vshell/backend/internal/refresh"
	"vshell/backend/internal/server"
)

const (
	timeout = 8 * time.Second
	// Keep probes in helper subprocesses with separate pipes. A blocked probe then
	// holds the helper pipes rather than the backend pipes. execbound limits
	// backend pipe reads if a descendant inherits them.
	waitDelay = execbound.DefaultWaitDelay
	// refreshSettle lets a run of subscribe frames collapse into one helper run.
	// The helper enumerates every backlight and DDC display, which is the
	// slowest snapshot this daemon owns.
	refreshSettle = 250 * time.Millisecond
)

type Manager struct {
	helper    string
	timeout   time.Duration
	waitDelay time.Duration
	log       *slog.Logger

	// state owns the newest successful helper listing and the goroutine that
	// refreshes it. Subscribe reads it instead of running the helper on the
	// subscribing connection.
	state *refresh.Service[any]
}

type setParams struct {
	Device  string `json:"device"`
	Percent int    `json:"percent"`
}

type stepParams struct {
	Device string `json:"device"`
	Step   int    `json:"step"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	helper, err := helperbin.Path()
	if err != nil {
		return nil, err
	}
	m := &Manager{helper: helper, timeout: timeout, waitDelay: waitDelay, log: log}
	m.state = refresh.NewService(srv, log, "brightness", refreshSettle, m.sweep)
	srv.Register("brightness", "brightness.getState", m.handleGetState)
	srv.Register("brightness", "brightness.rescan", m.handleGetState)
	// Keyed by device: a write to one display must never replace the waiting
	// write to another, or a lock blackout leaves a display lit.
	srv.RegisterLatest("brightness", "brightness.setBrightness", m.handleSetBrightness, deviceKey)
	srv.Register("brightness", "brightness.increment", m.handleIncrement)
	srv.Register("brightness", "brightness.decrement", m.handleDecrement)
	srv.Register("brightness", "brightness.subscribe", m.handleGetState)
	srv.CoalesceBroadcasts("brightness")
	srv.RegisterSnapshot("brightness", m.state.Cached)
	srv.RegisterSnapshotRefresh("brightness", m.state.Kick)
	return m, nil
}

func (m *Manager) Close() { m.state.Close() }

// deviceKey is the coalescing key for a per-display setter. Params that do not
// decode share the empty device the handler rejects, so a malformed call cannot
// displace a real write to a named display.
func deviceKey(params json.RawMessage) string {
	var p setParams
	if err := json.Unmarshal(params, &p); err != nil {
		return ""
	}
	return p.Device
}

func (m *Manager) handleGetState(json.RawMessage) (any, error) {
	return m.state.Query()
}

func (m *Manager) handleSetBrightness(params json.RawMessage) (any, error) {
	var p setParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.Device == "" {
		return nil, fmt.Errorf("device required")
	}
	if p.Percent < 0 || p.Percent > 100 {
		return nil, fmt.Errorf("percent out of range")
	}
	return m.call("set", p.Device, strconv.Itoa(p.Percent), "--json")
}

func (m *Manager) handleIncrement(params json.RawMessage) (any, error) {
	var p stepParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.Device == "" {
		return nil, fmt.Errorf("device required")
	}
	if p.Step <= 0 {
		p.Step = 10
	}
	return m.call("increment", p.Device, strconv.Itoa(p.Step), "--json")
}

func (m *Manager) handleDecrement(params json.RawMessage) (any, error) {
	var p stepParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.Device == "" {
		return nil, fmt.Errorf("device required")
	}
	if p.Step <= 0 {
		p.Step = 10
	}
	return m.call("decrement", p.Device, strconv.Itoa(p.Step), "--json")
}

func (m *Manager) sweep() (any, error) { return m.call("list", "--json") }

func (m *Manager) call(args ...string) (any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), m.timeout)
	defer cancel()
	cmdArgs := append([]string{"brightness"}, args...)
	res, err := execbound.CommandWithDelay(ctx, m.waitDelay, m.helper, cmdArgs...).WithLogger(m.log).Output()
	out := res.Out
	if err != nil {
		if errors.Is(err, execbound.ErrTimeout) {
			return nil, fmt.Errorf("brightness helper timed out")
		}
		if ee, ok := err.(*exec.ExitError); ok {
			msg := string(ee.Stderr)
			if msg == "" {
				msg = string(out)
			}
			if msg == "" {
				msg = "brightness helper failed"
			}
			return nil, fmt.Errorf("%s", msg)
		}
		return nil, err
	}
	var result any
	if err := json.Unmarshal(out, &result); err != nil {
		if res.Salvaged {
			// Name the abandoned descendant, not the JSON: the helper left its
			// pipes held open, so this output may be truncated or interleaved.
			return nil, fmt.Errorf("brightness helper left its pipes held open and its response did not decode: %w", err)
		}
		return nil, fmt.Errorf("decode brightness helper response: %w", err)
	}
	return result, nil
}
