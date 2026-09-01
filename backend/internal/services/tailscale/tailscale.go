package tailscale

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"vshell/backend/internal/execbound"
	"vshell/backend/internal/server"
)

const timeout = 12 * time.Second

type Manager struct {
	srv       *server.Server
	log       *slog.Logger
	tailscale string

	// ipn bus watcher (watch.go)
	watchCtx   context.Context
	watchStop  context.CancelFunc
	watchAlive atomic.Bool
	watchMu    sync.Mutex
	pushTimer  *time.Timer
	pushing    bool
	pushMissed bool
	lastPush   time.Time
}

type State struct {
	Connected              bool   `json:"connected"`
	Version                string `json:"version"`
	BackendState           string `json:"backendState"`
	MagicDNSSuffix         string `json:"magicDnsSuffix"`
	TailnetName            string `json:"tailnetName"`
	ExitNodeAllowLanAccess bool   `json:"exitNodeAllowLanAccess"`
	AcceptRoutes           bool   `json:"acceptRoutes"`
	AuthURL                string `json:"authUrl"`
	// WatcherActive is this backend's own health, not tailscaled's: true while
	// an ipn bus watcher is running and pushes can be expected. The shell reads
	// it to choose how often to re-ask. Absent on a backend without the watcher,
	// where it decodes as false — which is exactly right, since that backend
	// never pushes either.
	WatcherActive bool     `json:"watcherActive"`
	Health        []string `json:"health"`
	Self          *Peer    `json:"self"`
	Peers         []Peer   `json:"peers"`
}

type Peer struct {
	ID             string   `json:"id"`
	Hostname       string   `json:"hostname"`
	DNSName        string   `json:"dnsName"`
	TailscaleIP    string   `json:"tailscaleIp"`
	TailscaleIPv6  string   `json:"tailscaleIpv6"`
	OS             string   `json:"os"`
	Online         bool     `json:"online"`
	LastSeen       string   `json:"lastSeen"`
	ExitNode       bool     `json:"exitNode"`
	ExitNodeOption bool     `json:"exitNodeOption"`
	Tags           []string `json:"tags"`
	Owner          string   `json:"owner"`
	Relay          string   `json:"relay"`
	Active         bool     `json:"active"`
	RxBytes        int64    `json:"rxBytes"`
	TxBytes        int64    `json:"txBytes"`
}

type statusJSON struct {
	Version        string                     `json:"Version"`
	BackendState   string                     `json:"BackendState"`
	MagicDNSSuffix string                     `json:"MagicDNSSuffix"`
	Self           *nodeJSON                  `json:"Self"`
	Peer           map[string]nodeJSON        `json:"Peer"`
	CurrentTailnet currentTailnetJSON         `json:"CurrentTailnet"`
	User           map[string]userJSON        `json:"User"`
	ClientVersion  map[string]any             `json:"ClientVersion"`
	Health         []string                   `json:"Health"`
	Extra          map[string]json.RawMessage `json:"-"`
}

type currentTailnetJSON struct {
	Name           string `json:"Name"`
	MagicDNSSuffix string `json:"MagicDNSSuffix"`
}

type nodeJSON struct {
	ID             string         `json:"ID"`
	HostName       string         `json:"HostName"`
	DNSName        string         `json:"DNSName"`
	OS             string         `json:"OS"`
	UserID         int64          `json:"UserID"`
	TailscaleIPs   []string       `json:"TailscaleIPs"`
	Online         bool           `json:"Online"`
	LastSeen       string         `json:"LastSeen"`
	ExitNode       bool           `json:"ExitNode"`
	ExitNodeOption bool           `json:"ExitNodeOption"`
	Relay          string         `json:"Relay"`
	Active         bool           `json:"Active"`
	RxBytes        int64          `json:"RxBytes"`
	TxBytes        int64          `json:"TxBytes"`
	Tags           []string       `json:"Tags"`
	CapMap         map[string]any `json:"CapMap"`
}

type userJSON struct {
	LoginName   string `json:"LoginName"`
	DisplayName string `json:"DisplayName"`
}

type prefsJSON struct {
	RouteAll               bool `json:"RouteAll"`
	ExitNodeAllowLANAccess bool `json:"ExitNodeAllowLANAccess"`
}

type exitNodeParams struct {
	ID string `json:"id"`
}

type lanParams struct {
	Enabled bool `json:"enabled"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	path, err := exec.LookPath("tailscale")
	if err != nil {
		return nil, fmt.Errorf("tailscale not found")
	}
	m := &Manager{srv: srv, log: log, tailscale: path}
	m.watchCtx, m.watchStop = context.WithCancel(context.Background())
	srv.Register("tailscale", "tailscale.getStatus", m.handleGetStatus)
	srv.Register("tailscale", "tailscale.refresh", m.handleRefresh)
	srv.Register("tailscale", "tailscale.connect", m.handleConnect)
	srv.Register("tailscale", "tailscale.disconnect", m.handleDisconnect)
	srv.Register("tailscale", "tailscale.setExitNode", m.handleSetExitNode)
	srv.Register("tailscale", "tailscale.setAllowLanAccess", m.handleSetAllowLANAccess)
	srv.Register("tailscale", "tailscale.setAcceptRoutes", m.handleSetAcceptRoutes)
	srv.RegisterSnapshot("tailscale", func() any {
		state, err := m.status()
		if err != nil {
			return map[string]any{"connected": false, "peers": []any{}, "error": err.Error()}
		}
		return state
	})
	// Event-only capability: it carries no method of its own, it tells the
	// shell that this backend pushes tailscale updates instead of only
	// answering them, so the shell can drop its re-fetch cadence to a bare
	// liveness backstop. See docs/architecture/backend-methods.json.
	srv.AddCapability("tailscale.watch")
	m.startWatch()
	return m, nil
}

func (m *Manager) Close() { m.stopWatch() }

func (m *Manager) handleGetStatus(json.RawMessage) (any, error) {
	return m.status()
}

func (m *Manager) handleRefresh(json.RawMessage) (any, error) {
	state, err := m.status()
	if err != nil {
		return nil, err
	}
	m.srv.Broadcast("tailscale", state)
	return state, nil
}

func (m *Manager) handleConnect(json.RawMessage) (any, error) {
	out, err := m.outputCombined("up")
	if url := findAuthURL(string(out)); url != "" {
		state := m.authState(url)
		m.srv.Broadcast("tailscale", state)
		return state, nil
	}
	if err != nil {
		return nil, err
	}
	return m.handleRefresh(nil)
}

func (m *Manager) handleDisconnect(json.RawMessage) (any, error) {
	if err := m.run("down"); err != nil {
		return nil, err
	}
	return m.handleRefresh(nil)
}

func (m *Manager) handleSetExitNode(params json.RawMessage) (any, error) {
	var p exitNodeParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	target, err := m.resolveExitNodeTarget(strings.TrimSpace(p.ID))
	if err != nil {
		return nil, err
	}
	if err := m.run("set", "--exit-node="+target); err != nil {
		return nil, err
	}
	return m.handleRefresh(nil)
}

func (m *Manager) handleSetAllowLANAccess(params json.RawMessage) (any, error) {
	var p lanParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.run("set", fmt.Sprintf("--exit-node-allow-lan-access=%t", p.Enabled)); err != nil {
		return nil, err
	}
	return m.handleRefresh(nil)
}

func (m *Manager) handleSetAcceptRoutes(params json.RawMessage) (any, error) {
	var p lanParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	arg := "--accept-routes=false"
	if p.Enabled {
		arg = "--accept-routes"
	}
	if err := m.run("set", arg); err != nil {
		return nil, err
	}
	return m.handleRefresh(nil)
}

func (m *Manager) status() (State, error) {
	out, err := m.output("status", "--json")
	if err != nil {
		return State{}, err
	}
	var raw statusJSON
	if err := json.Unmarshal(out, &raw); err != nil {
		return State{}, fmt.Errorf("decode tailscale status: %w", err)
	}
	state := State{
		Connected:      strings.EqualFold(raw.BackendState, "Running"),
		WatcherActive:  m.watcherActive(),
		Version:        raw.Version,
		BackendState:   raw.BackendState,
		MagicDNSSuffix: firstNonEmpty(raw.MagicDNSSuffix, raw.CurrentTailnet.MagicDNSSuffix),
		TailnetName:    raw.CurrentTailnet.Name,
	}
	if state.Connected {
		state.Health = append([]string{}, raw.Health...)
	}
	if raw.Self != nil {
		self := mapPeer(*raw.Self, raw.User)
		state.Self = &self
	}
	keys := make([]string, 0, len(raw.Peer))
	for key := range raw.Peer {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		peer := mapPeer(raw.Peer[key], raw.User)
		state.Peers = append(state.Peers, peer)
		if peer.ExitNode {
			state.ExitNodeAllowLanAccess = detectLANAccess(peer)
		}
	}
	if state.Peers == nil {
		state.Peers = []Peer{}
	}
	if prefs, err := m.prefs(); err == nil {
		state.AcceptRoutes = prefs.RouteAll
		state.ExitNodeAllowLanAccess = prefs.ExitNodeAllowLANAccess
	}
	return state, nil
}

func (m *Manager) authState(authURL string) State {
	state, err := m.status()
	if err != nil {
		state = State{BackendState: "NeedsLogin", Peers: []Peer{}, Health: []string{}}
	}
	state.AuthURL = authURL
	if state.BackendState == "" {
		state.BackendState = "NeedsLogin"
	}
	if state.Peers == nil {
		state.Peers = []Peer{}
	}
	if state.Health == nil {
		state.Health = []string{}
	}
	return state
}

func (m *Manager) prefs() (prefsJSON, error) {
	out, err := m.output("debug", "prefs")
	if err != nil {
		return prefsJSON{}, err
	}
	var prefs prefsJSON
	if err := json.Unmarshal(out, &prefs); err != nil {
		return prefsJSON{}, fmt.Errorf("decode tailscale prefs: %w", err)
	}
	return prefs, nil
}

func (m *Manager) resolveExitNodeTarget(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	state, err := m.status()
	if err != nil {
		return "", err
	}
	for _, peer := range state.Peers {
		if !peer.ExitNodeOption {
			continue
		}
		if matchesPeer(value, peer) {
			return peerExitNodeTarget(peer), nil
		}
	}
	return "", fmt.Errorf("exit node not available")
}

func (m *Manager) output(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	res, err := execbound.Command(ctx, m.tailscale, args...).WithLogger(m.log).Output()
	if err != nil {
		if errors.Is(err, execbound.ErrTimeout) {
			return nil, fmt.Errorf("tailscale %s timed out", strings.Join(args, " "))
		}
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			return nil, fmt.Errorf("%s", strings.TrimSpace(string(ee.Stderr)))
		}
		return nil, err
	}
	return res.Out, nil
}

func (m *Manager) outputCombined(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	res, err := execbound.Command(ctx, m.tailscale, args...).WithLogger(m.log).CombinedOutput()
	if errors.Is(err, execbound.ErrTimeout) {
		return res.Out, fmt.Errorf("tailscale %s timed out", strings.Join(args, " "))
	}
	if err != nil && len(res.Out) > 0 {
		return res.Out, fmt.Errorf("%s", strings.TrimSpace(string(res.Out)))
	}
	return res.Out, err
}

func (m *Manager) run(args ...string) error {
	_, err := m.output(args...)
	return err
}

func mapPeer(n nodeJSON, users map[string]userJSON) Peer {
	var ipv4, ipv6 string
	for _, ip := range n.TailscaleIPs {
		if strings.Contains(ip, ":") {
			if ipv6 == "" {
				ipv6 = ip
			}
		} else if ipv4 == "" {
			ipv4 = ip
		}
	}
	owner := ""
	if user, ok := users[fmt.Sprint(n.UserID)]; ok {
		owner = firstNonEmpty(user.DisplayName, user.LoginName)
	}
	return Peer{
		ID:             firstNonEmpty(n.ID, n.HostName),
		Hostname:       n.HostName,
		DNSName:        n.DNSName,
		TailscaleIP:    ipv4,
		TailscaleIPv6:  ipv6,
		OS:             n.OS,
		Online:         n.Online,
		LastSeen:       n.LastSeen,
		ExitNode:       n.ExitNode,
		ExitNodeOption: n.ExitNodeOption,
		Tags:           append([]string{}, n.Tags...),
		Owner:          owner,
		Relay:          n.Relay,
		Active:         n.Active,
		RxBytes:        n.RxBytes,
		TxBytes:        n.TxBytes,
	}
}

func detectLANAccess(Peer) bool {
	// tailscale status --json does not expose this setting consistently across
	// versions. Keep the frontend field stable; actions still set it explicitly.
	return false
}

func matchesPeer(value string, peer Peer) bool {
	trimDNS := strings.TrimSuffix(peer.DNSName, ".")
	return value == peer.ID ||
		value == peer.Hostname ||
		value == peer.DNSName ||
		value == trimDNS ||
		value == peer.TailscaleIP ||
		value == peer.TailscaleIPv6
}

func peerExitNodeTarget(peer Peer) string {
	if peer.TailscaleIP != "" {
		return peer.TailscaleIP
	}
	if peer.DNSName != "" {
		return strings.TrimSuffix(peer.DNSName, ".")
	}
	return peer.Hostname
}

func findAuthURL(text string) string {
	for _, field := range strings.Fields(text) {
		candidate := strings.Trim(field, "\"'()[]{}<>,")
		if (strings.HasPrefix(candidate, "https://") || strings.HasPrefix(candidate, "http://")) && strings.Contains(candidate, "login") {
			return candidate
		}
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
