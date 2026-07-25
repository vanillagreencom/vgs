package evdev

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"vshell/backend/internal/server"
)

const pollInterval = 500 * time.Millisecond

type Manager struct {
	srv  *server.Server
	log  *slog.Logger
	done chan struct{}
	wg   sync.WaitGroup

	mu    sync.RWMutex
	state State
}

type State struct {
	CapsLock bool     `json:"capsLock"`
	Devices  []string `json:"devices"`
	Backend  string   `json:"backend"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	paths, err := capsLockLEDs()
	if err != nil {
		return nil, err
	}
	state := State{Devices: paths, Backend: "sysfs-leds"}
	state.CapsLock, _ = readCapsLock(paths)
	m := &Manager{srv: srv, log: log, done: make(chan struct{}), state: state}
	srv.Register("evdev", "evdev.getState", m.handleGetState)
	srv.Register("evdev", "evdev.subscribe", m.handleGetState)
	srv.RegisterSnapshot("evdev", m.snapshot)
	m.wg.Add(1)
	go m.poll()
	return m, nil
}

func (m *Manager) Close() {
	close(m.done)
	m.wg.Wait()
}

func (m *Manager) handleGetState(json.RawMessage) (any, error) {
	return m.refresh(), nil
}

func (m *Manager) snapshot() any {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.state
}

// refresh re-reads the LED state and broadcasts on change. Both the poller and
// getState calls go through here, so a getState between two ticks cannot
// swallow a transition from the poller's change detection.
func (m *Manager) refresh() State {
	m.mu.RLock()
	paths := append([]string{}, m.state.Devices...)
	m.mu.RUnlock()
	current, readable := readCapsLock(paths)
	if !readable {
		// Every LED path failed to read (e.g. the keyboard was replugged and
		// its sysfs path changed); rescan so the indicator can recover.
		if rescanned, err := capsLockLEDs(); err == nil {
			paths = rescanned
			current, _ = readCapsLock(paths)
			m.mu.Lock()
			m.state.Devices = paths
			m.mu.Unlock()
		} else {
			m.log.Debug("capslock LED rescan failed", "err", err)
		}
	}
	m.mu.Lock()
	changed := m.state.CapsLock != current
	m.state.CapsLock = current
	state := m.state
	m.mu.Unlock()
	if changed {
		m.srv.Broadcast("evdev", state)
	}
	return state
}

func (m *Manager) poll() {
	defer m.wg.Done()
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-m.done:
			return
		case <-ticker.C:
			m.refresh()
		}
	}
}

func capsLockLEDs() ([]string, error) {
	matches, err := filepath.Glob("/sys/class/leds/*capslock*/brightness")
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, path := range matches {
		if _, err := os.Stat(path); err == nil {
			paths = append(paths, path)
		}
	}
	if len(paths) == 0 {
		return nil, fmt.Errorf("no capslock LEDs found")
	}
	return paths, nil
}

// readCapsLock reports whether any LED is lit and whether any path was
// readable at all (readable=false means the device list is stale).
func readCapsLock(paths []string) (on bool, readable bool) {
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		readable = true
		if strings.TrimSpace(string(raw)) != "0" {
			return true, true
		}
	}
	return false, readable
}
