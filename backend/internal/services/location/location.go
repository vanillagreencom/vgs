package location

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"vshell/backend/internal/server"
)

const ipLookupURL = "http://ip-api.com/json/"

// cacheTTL bounds how long a cached IP fix is served without refetching, so a
// machine that moved (travel, VPN egress change) does not keep feeding stale
// coordinates to sunrise/sunset consumers forever.
const cacheTTL = 12 * time.Hour

type State struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	City      string  `json:"city,omitempty"`
	Country   string  `json:"country,omitempty"`
	Provider  string  `json:"provider,omitempty"`
	UpdatedAt string  `json:"updatedAt,omitempty"`
}

type Manager struct {
	log *slog.Logger
	srv *server.Server

	mu        sync.RWMutex
	state     State
	cachePath string

	client *http.Client
}

type ipAPIResponse struct {
	Status  string  `json:"status"`
	Message string  `json:"message"`
	Lat     float64 `json:"lat"`
	Lon     float64 `json:"lon"`
	City    string  `json:"city"`
	Country string  `json:"country"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	if log == nil {
		log = slog.Default()
	}
	m := &Manager{
		log:       log,
		srv:       srv,
		cachePath: cacheFilePath(),
		client:    &http.Client{Timeout: 10 * time.Second},
	}
	m.state = m.loadCachedState()

	srv.Register("location", "location.getState", m.handleGetState)
	srv.Register("location", "location.subscribe", m.handleSubscribe)
	srv.RegisterSnapshot("location", func() any { return m.GetState() })

	if stale(m.state) {
		go func() {
			if _, err := m.refreshFromIP(); err != nil {
				m.log.Warn("location lookup failed", "err", err)
			}
		}()
	}

	return m, nil
}

func (m *Manager) Close() {}

func (m *Manager) GetState() State {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.state
}

func (m *Manager) handleSubscribe(json.RawMessage) (any, error) {
	return m.handleGetState(nil)
}

func (m *Manager) handleGetState(json.RawMessage) (any, error) {
	state := m.GetState()
	if !stale(state) {
		return state, nil
	}
	fresh, err := m.refreshFromIP()
	if err != nil {
		if valid(state) {
			// Offline or lookup down: a stale fix beats an error.
			m.log.Warn("location refresh failed, serving cached location", "err", err)
			return state, nil
		}
		return nil, err
	}
	return fresh, nil
}

func (m *Manager) refreshFromIP() (State, error) {
	req, err := http.NewRequest(http.MethodGet, ipLookupURL, nil)
	if err != nil {
		return State{}, err
	}
	resp, err := m.client.Do(req)
	if err != nil {
		return State{}, fmt.Errorf("fetch IP location: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return State{}, fmt.Errorf("ip-api.com returned status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return State{}, fmt.Errorf("read IP location response: %w", err)
	}
	var data ipAPIResponse
	if err := json.Unmarshal(body, &data); err != nil {
		return State{}, fmt.Errorf("decode IP location response: %w", err)
	}
	if data.Status == "fail" || (data.Lat == 0 && data.Lon == 0) {
		if data.Message != "" {
			return State{}, fmt.Errorf("IP location unavailable: %s", data.Message)
		}
		return State{}, fmt.Errorf("IP location unavailable")
	}
	state := State{
		Latitude:  data.Lat,
		Longitude: data.Lon,
		City:      data.City,
		Country:   data.Country,
		Provider:  "ip-api",
		UpdatedAt: time.Now().Format(time.RFC3339),
	}
	m.setState(state)
	return state, nil
}

func (m *Manager) setState(state State) {
	m.mu.Lock()
	changed := m.state.Latitude != state.Latitude ||
		m.state.Longitude != state.Longitude ||
		m.state.City != state.City ||
		m.state.Country != state.Country ||
		m.state.Provider != state.Provider
	m.state = state
	m.mu.Unlock()
	m.saveCachedState(state)
	if changed {
		m.srv.Broadcast("location", state)
	}
}

func valid(state State) bool {
	return state.Latitude != 0 || state.Longitude != 0
}

func stale(state State) bool {
	if !valid(state) {
		return true
	}
	updated, err := time.Parse(time.RFC3339, state.UpdatedAt)
	if err != nil {
		return true // legacy cache entries without a timestamp
	}
	return time.Since(updated) > cacheTTL
}

func cacheFilePath() string {
	base := os.Getenv("XDG_CACHE_HOME")
	if base == "" {
		if home, err := os.UserHomeDir(); err == nil {
			base = filepath.Join(home, ".cache")
		} else {
			base = os.TempDir()
		}
	}
	return filepath.Join(base, "vshell", "location.json")
}

func (m *Manager) loadCachedState() State {
	data, err := os.ReadFile(m.cachePath)
	if err != nil {
		return State{}
	}
	var state State
	if err := json.Unmarshal(data, &state); err != nil {
		return State{}
	}
	return state
}

func (m *Manager) saveCachedState(state State) {
	if !valid(state) {
		return
	}
	if err := os.MkdirAll(filepath.Dir(m.cachePath), 0o755); err != nil {
		m.log.Warn("location: failed to create cache dir", "err", err)
		return
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		m.log.Warn("location: failed to encode cache", "err", err)
		return
	}
	if err := os.WriteFile(m.cachePath, data, 0o600); err != nil {
		m.log.Warn("location: failed to write cache", "err", err)
	}
}
