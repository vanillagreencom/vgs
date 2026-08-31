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
	"time"

	"vshell/backend/internal/server"
)

const (
	timeout = 8 * time.Second
	// Bounds how long Output waits on stdout/stderr pipes after the timeout's
	// kill lands on the helper. The killed helper's wedged descendants
	// (ddcutil in uninterruptible sleep on a dead i2c bus) inherit the pipes
	// and never close them; without this, Output reads toward EOF forever.
	// It cannot abandon a helper that is itself in uninterruptible sleep —
	// Wait blocks in wait4 regardless — so probes that can D-state must stay
	// in subprocesses of the helper, never in the helper's own process.
	waitDelay = 2 * time.Second
)

type Manager struct {
	helper    string
	timeout   time.Duration
	waitDelay time.Duration
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
	m := &Manager{helper: helper, timeout: timeout, waitDelay: waitDelay}
	srv.Register("brightness", "brightness.getState", m.handleGetState)
	srv.Register("brightness", "brightness.rescan", m.handleGetState)
	srv.Register("brightness", "brightness.setBrightness", m.handleSetBrightness)
	srv.Register("brightness", "brightness.increment", m.handleIncrement)
	srv.Register("brightness", "brightness.decrement", m.handleDecrement)
	srv.Register("brightness", "brightness.subscribe", m.handleGetState)
	srv.RegisterSnapshot("brightness", func() any {
		state, err := m.state()
		if err != nil {
			return map[string]any{"devices": []any{}, "errors": []string{err.Error()}}
		}
		return state
	})
	return m, nil
}

func (m *Manager) Close() {}

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
	return m.call("list", "--json")
}

func (m *Manager) call(args ...string) (any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), m.timeout)
	defer cancel()
	cmdArgs := append([]string{"brightness"}, args...)
	cmd := exec.CommandContext(ctx, m.helper, cmdArgs...)
	cmd.WaitDelay = m.waitDelay
	out, err := cmd.Output()
	// Salvage before the timeout classification: a helper can exit cleanly
	// with the complete response and the deadline expire while Output still
	// waits on a descendant-held pipe, making both conditions true at once.
	if errors.Is(err, exec.ErrWaitDelay) {
		var result any
		if jsonErr := json.Unmarshal(out, &result); jsonErr == nil {
			return result, nil
		}
		if ctx.Err() == context.DeadlineExceeded {
			return nil, fmt.Errorf("brightness helper timed out")
		}
		return nil, fmt.Errorf("brightness helper left its pipes held open")
	}
	if ctx.Err() == context.DeadlineExceeded {
		return nil, fmt.Errorf("brightness helper timed out")
	}
	if err != nil {
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
