package brightnessbridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"vshell/backend/internal/execbound"
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
	srv       *server.Server
	helper    string
	timeout   time.Duration
	waitDelay time.Duration
	log       *slog.Logger

	mu sync.Mutex
	// lastState is the newest successful helper listing. Subscribe reads it
	// instead of running the helper on the subscribing connection.
	lastState any
	hasLast   bool

	// refreshes runs the helper off the subscribe path and broadcasts its
	// result.
	refreshes *refresh.Loop
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
	helper, err := helperPath()
	if err != nil {
		return nil, err
	}
	m := &Manager{srv: srv, helper: helper, timeout: timeout, waitDelay: waitDelay, log: log}
	srv.Register("brightness", "brightness.getState", m.handleGetState)
	srv.Register("brightness", "brightness.rescan", m.handleGetState)
	srv.RegisterLatest("brightness", "brightness.setBrightness", m.handleSetBrightness)
	srv.Register("brightness", "brightness.increment", m.handleIncrement)
	srv.Register("brightness", "brightness.decrement", m.handleDecrement)
	srv.Register("brightness", "brightness.subscribe", m.handleGetState)
	m.refreshes = refresh.NewLoop(refreshSettle, m.refreshAndBroadcast)
	srv.RegisterSnapshot("brightness", m.cachedState)
	srv.RegisterSnapshotRefresh("brightness", m.refreshes.Kick)
	return m, nil
}

func (m *Manager) Close() { m.refreshes.Close() }

// cachedState returns the newest successful helper listing, or nil before the
// first one completes. An empty device list would reach the shell as "no
// backlights" and hide the brightness control the kicked refresh is about to
// populate.
func (m *Manager) cachedState() any {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.hasLast {
		return nil
	}
	return m.lastState
}

func (m *Manager) refreshAndBroadcast() {
	state, err := m.state()
	if err != nil {
		// Keep the subscribers' last-known devices instead of broadcasting an
		// empty list as truth.
		m.log.Warn("brightness refresh failed, skipping broadcast", "err", err)
		return
	}
	m.srv.Broadcast("brightness", state)
}

func (m *Manager) handleGetState(json.RawMessage) (any, error) {
	return m.state()
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

func (m *Manager) state() (any, error) {
	state, err := m.call("list", "--json")
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	m.lastState = state
	m.hasLast = true
	m.mu.Unlock()
	return state, nil
}

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

func helperPath() (string, error) {
	if root := os.Getenv("VSHELL_ROOT"); root != "" {
		path := filepath.Join(root, "bin", "vshell-helper")
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			return path, nil
		}
	}
	exe, err := os.Executable()
	if err == nil {
		path := filepath.Join(filepath.Dir(filepath.Dir(filepath.Dir(exe))), "bin", "vshell-helper")
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			return path, nil
		}
	}
	if path, err := exec.LookPath("vshell-helper"); err == nil {
		return path, nil
	}
	return "", fmt.Errorf("vshell-helper not found")
}
