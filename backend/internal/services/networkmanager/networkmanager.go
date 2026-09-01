package networkmanager

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"vshell/backend/internal/execbound"
	"vshell/backend/internal/server"
)

const commandTimeout = 20 * time.Second

type Manager struct {
	srv *server.Server
	log *slog.Logger

	mu      sync.Mutex
	pending map[string]pendingPrompt
	// preference is the last network.preference.set value; nmcli has no way to
	// read it back, so it is remembered here instead of hardcoding "auto" and
	// resetting the UI selection on every broadcast.
	preference string
	stop       chan struct{}
	// kick coalesces monitor events into single-flight state broadcasts; see
	// broadcastLoop.
	kick chan struct{}
}

type pendingPrompt struct {
	SSID   string
	Device string
	Hidden bool
}

type networkState struct {
	Backend                string           `json:"backend"`
	NetworkStatus          string           `json:"networkStatus"`
	PrimaryConnection      string           `json:"primaryConnection"`
	Preference             string           `json:"preference"`
	EthernetIP             string           `json:"ethernetIP"`
	EthernetDevice         string           `json:"ethernetDevice"`
	EthernetConnected      bool             `json:"ethernetConnected"`
	EthernetConnectionUUID string           `json:"ethernetConnectionUuid"`
	EthernetDevices        []ethernetDevice `json:"ethernetDevices"`
	WiredConnections       []wiredConn      `json:"wiredConnections"`
	WiFiIP                 string           `json:"wifiIP"`
	WiFiDevice             string           `json:"wifiDevice"`
	WiFiDevicePath         string           `json:"wifiDevicePath"`
	WiFiConnected          bool             `json:"wifiConnected"`
	WiFiEnabled            bool             `json:"wifiEnabled"`
	WiFiConnectionUUID     string           `json:"wifiConnectionUuid"`
	WiFiSSID               string           `json:"wifiSSID"`
	WiFiBSSID              string           `json:"wifiBSSID"`
	WiFiSignal             int              `json:"wifiSignal"`
	WiFiNetworks           []wifiNetwork    `json:"wifiNetworks"`
	SavedWiFiNetworks      []wifiNetwork    `json:"savedWifiNetworks"`
	WiFiDevices            []wifiDevice     `json:"wifiDevices"`
	VPNProfiles            []vpnProfile     `json:"vpnProfiles"`
	VPNActive              []vpnActive      `json:"vpnActive"`
	IsConnecting           bool             `json:"isConnecting"`
	ConnectingSSID         string           `json:"connectingSSID"`
	LastError              string           `json:"lastError"`
}

type wifiNetwork struct {
	SSID        string `json:"ssid"`
	BSSID       string `json:"bssid"`
	Signal      int    `json:"signal"`
	Secured     bool   `json:"secured"`
	Enterprise  bool   `json:"enterprise"`
	Connected   bool   `json:"connected"`
	Saved       bool   `json:"saved"`
	Autoconnect bool   `json:"autoconnect"`
	Hidden      bool   `json:"hidden"`
	OutOfRange  bool   `json:"outOfRange"`
	Frequency   int    `json:"frequency"`
	Mode        string `json:"mode"`
	Rate        int    `json:"rate"`
	Channel     int    `json:"channel"`
	Device      string `json:"device,omitempty"`
}

type wifiDevice struct {
	Name      string        `json:"name"`
	HwAddress string        `json:"hwAddress"`
	State     string        `json:"state"`
	Connected bool          `json:"connected"`
	SSID      string        `json:"ssid,omitempty"`
	BSSID     string        `json:"bssid,omitempty"`
	Signal    int           `json:"signal,omitempty"`
	IP        string        `json:"ip,omitempty"`
	Networks  []wifiNetwork `json:"networks"`
}

type ethernetDevice struct {
	Name      string `json:"name"`
	HwAddress string `json:"hwAddress"`
	State     string `json:"state"`
	Connected bool   `json:"connected"`
	IP        string `json:"ip,omitempty"`
	Speed     int    `json:"speed,omitempty"`
	Driver    string `json:"driver,omitempty"`
}

type wiredConn struct {
	Path     string `json:"path"`
	ID       string `json:"id"`
	UUID     string `json:"uuid"`
	Type     string `json:"type"`
	IsActive bool   `json:"isActive"`
}

type vpnProfile struct {
	Name        string            `json:"name"`
	UUID        string            `json:"uuid"`
	Type        string            `json:"type"`
	ServiceType string            `json:"serviceType"`
	TypeLabel   string            `json:"typeLabel,omitempty"`
	Autoconnect bool              `json:"autoconnect"`
	Data        map[string]string `json:"data,omitempty"`
}

type vpnActive struct {
	Name        string            `json:"name"`
	UUID        string            `json:"uuid"`
	Device      string            `json:"device,omitempty"`
	State       string            `json:"state,omitempty"`
	Type        string            `json:"type"`
	ServiceType string            `json:"serviceType"`
	Data        map[string]string `json:"data,omitempty"`
}

type connectWiFiParams struct {
	SSID              string `json:"ssid"`
	Password          string `json:"password"`
	Username          string `json:"username"`
	AnonymousIdentity string `json:"anonymousIdentity"`
	DomainSuffixMatch string `json:"domainSuffixMatch"`
	Interactive       bool   `json:"interactive"`
	Hidden            bool   `json:"hidden"`
	Device            string `json:"device"`
}

type deviceParams struct {
	Device string `json:"device"`
}

type ssidParams struct {
	SSID string `json:"ssid"`
}

type autoconnectParams struct {
	SSID        string `json:"ssid"`
	Autoconnect bool   `json:"autoconnect"`
}

type preferenceParams struct {
	Preference string `json:"preference"`
}

type uuidParams struct {
	UUID       string `json:"uuid"`
	UUIDOrName string `json:"uuidOrName"`
	Name       string `json:"name"`
}

type credentialsParams struct {
	Token   string            `json:"token"`
	Secrets map[string]string `json:"secrets"`
	Save    bool              `json:"save"`
}

type vpnImportParams struct {
	File string `json:"file"`
	Name string `json:"name"`
}

type vpnUpdateParams struct {
	UUID        string            `json:"uuid"`
	Name        string            `json:"name"`
	Autoconnect *bool             `json:"autoconnect"`
	Data        map[string]string `json:"data"`
}

type vpnCredentialsParams struct {
	UUID     string `json:"uuid"`
	Username string `json:"username"`
	Password string `json:"password"`
	Save     bool   `json:"save"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	if log == nil {
		log = slog.Default()
	}
	if _, err := exec.LookPath("nmcli"); err != nil {
		return nil, fmt.Errorf("nmcli not found: %w", err)
	}
	if out, err := runNMCLI("-t", "-f", "RUNNING", "general"); err != nil || strings.TrimSpace(strings.ToLower(out)) != "running" {
		if err != nil {
			return nil, fmt.Errorf("NetworkManager unavailable: %w", err)
		}
		return nil, fmt.Errorf("NetworkManager unavailable")
	}
	m := &Manager{srv: srv, log: log, pending: map[string]pendingPrompt{}, preference: "auto", stop: make(chan struct{}), kick: make(chan struct{}, 1)}
	for method, handler := range map[string]server.HandlerFunc{
		"network.getState":                m.handleGetState,
		"network.wifi.scan":               m.handleWiFiScan,
		"network.wifi.networks":           m.handleWiFiNetworks,
		"network.wifi.connect":            m.handleWiFiConnect,
		"network.wifi.disconnect":         m.handleWiFiDisconnect,
		"network.wifi.forget":             m.handleWiFiForget,
		"network.wifi.toggle":             m.handleWiFiToggle,
		"network.wifi.enable":             m.handleWiFiEnable,
		"network.wifi.disable":            m.handleWiFiDisable,
		"network.wifi.setAutoconnect":     m.handleWiFiSetAutoconnect,
		"network.credentials.submit":      m.handleCredentialsSubmit,
		"network.credentials.cancel":      m.handleCredentialsCancel,
		"network.ethernet.connect":        m.handleEthernetConnect,
		"network.ethernet.connect.config": m.handleEthernetConnectConfig,
		"network.ethernet.disconnect":     m.handleEthernetDisconnect,
		"network.ethernet.info":           m.handleEthernetInfo,
		"network.preference.set":          m.handlePreferenceSet,
		"network.info":                    m.handleNetworkInfo,
		"network.vpn.profiles":            m.handleVPNProfiles,
		"network.vpn.active":              m.handleVPNActive,
		"network.vpn.connect":             m.handleVPNConnect,
		"network.vpn.disconnect":          m.handleVPNDisconnect,
		"network.vpn.disconnectAll":       m.handleVPNDisconnectAll,
		"network.vpn.plugins":             m.handleVPNPlugins,
		"network.vpn.import":              m.handleVPNImport,
		"network.vpn.getConfig":           m.handleVPNGetConfig,
		"network.vpn.updateConfig":        m.handleVPNUpdateConfig,
		"network.vpn.delete":              m.handleVPNDelete,
		"network.vpn.setCredentials":      m.handleVPNSetCredentials,
		"network.vpn.clearCredentials":    m.handleVPNClearCredentials,
	} {
		srv.Register("network", method, handler)
	}
	srv.RegisterSnapshot("network", func() any { return m.state() })
	go m.monitor()
	go m.broadcastLoop()
	return m, nil
}

func (m *Manager) Close() {
	close(m.stop)
}

func (m *Manager) handleGetState(json.RawMessage) (any, error) {
	return m.stateChecked()
}

func (m *Manager) handleWiFiNetworks(json.RawMessage) (any, error) {
	return m.state().WiFiNetworks, nil
}

func (m *Manager) handleWiFiScan(params json.RawMessage) (any, error) {
	var p deviceParams
	_ = json.Unmarshal(params, &p)
	args := []string{"device", "wifi", "rescan"}
	if p.Device != "" {
		args = append(args, "ifname", p.Device)
	}
	if _, err := runNMCLI(args...); err != nil {
		return nil, err
	}
	m.broadcastSoon()
	return ok("scanning"), nil
}

func (m *Manager) handleWiFiConnect(params json.RawMessage) (any, error) {
	var p connectWiFiParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	p.SSID = strings.TrimSpace(p.SSID)
	if err := validateSSID(p.SSID); err != nil {
		return nil, err
	}
	if p.Interactive && p.Password == "" && p.Username == "" {
		token := tokenForSSID(p.SSID)
		m.mu.Lock()
		m.pending[token] = pendingPrompt{SSID: p.SSID, Device: p.Device, Hidden: p.Hidden}
		m.mu.Unlock()
		fields := []string{"psk"}
		if networkEnterprise(m.state().WiFiNetworks, p.SSID) {
			fields = []string{"identity", "password"}
		}
		m.srv.Broadcast("network.credentials", map[string]any{
			"token":   token,
			"ssid":    p.SSID,
			"setting": "802-11-wireless-security",
			"fields":  fields,
			"reason":  "Credentials required",
		})
		return ok("credentials requested"), nil
	}
	if err := m.connectWiFi(p); err != nil {
		return nil, err
	}
	m.broadcastSoon()
	return ok("connecting"), nil
}

func (m *Manager) handleCredentialsSubmit(params json.RawMessage) (any, error) {
	var p credentialsParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	m.mu.Lock()
	prompt, ok := m.pending[p.Token]
	delete(m.pending, p.Token)
	m.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("credential prompt not found")
	}
	connReq := connectWiFiParams{SSID: prompt.SSID, Device: prompt.Device, Hidden: prompt.Hidden}
	connReq.Password = firstNonEmpty(p.Secrets["psk"], p.Secrets["password"])
	connReq.Username = firstNonEmpty(p.Secrets["identity"], p.Secrets["username"])
	if err := m.connectWiFi(connReq); err != nil {
		return nil, err
	}
	m.broadcastSoon()
	return okResult(true, "credentials submitted"), nil
}

func (m *Manager) handleCredentialsCancel(params json.RawMessage) (any, error) {
	var p credentialsParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	m.mu.Lock()
	delete(m.pending, p.Token)
	m.mu.Unlock()
	return okResult(true, "credentials cancelled"), nil
}

func (m *Manager) handleWiFiDisconnect(params json.RawMessage) (any, error) {
	var p deviceParams
	_ = json.Unmarshal(params, &p)
	if p.Device != "" {
		if _, err := runNMCLI("device", "disconnect", p.Device); err != nil {
			return nil, err
		}
	} else if dev := m.state().WiFiDevice; dev != "" {
		if _, err := runNMCLI("device", "disconnect", dev); err != nil {
			return nil, err
		}
	}
	m.broadcastSoon()
	return ok("disconnected"), nil
}

func (m *Manager) handleWiFiForget(params json.RawMessage) (any, error) {
	var p ssidParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.SSID) == "" {
		return nil, fmt.Errorf("ssid required")
	}
	var errs []string
	for _, uuid := range m.wifiProfileUUIDs(p.SSID) {
		if _, err := runNMCLI("connection", "delete", "uuid", uuid); err != nil {
			errs = append(errs, err.Error())
		}
	}
	m.broadcastSoon()
	if len(errs) > 0 {
		return nil, fmt.Errorf("forget %s: %s", p.SSID, strings.Join(errs, "; "))
	}
	return ok("forgotten"), nil
}

// wifiProfileUUIDs returns saved Wi-Fi profiles matching ssid, by profile name
// or by the profile's stored 802-11-wireless.ssid. NM often auto-names
// profiles ("MyWifi 1") or users rename them, so name alone silently misses
// real matches.
func (m *Manager) wifiProfileUUIDs(ssid string) []string {
	var uuids []string
	for _, c := range m.savedConnections() {
		if c["type"] != "802-11-wireless" {
			continue
		}
		if c["name"] == ssid {
			uuids = append(uuids, c["uuid"])
			continue
		}
		out, err := runNMCLI("-g", "802-11-wireless.ssid", "connection", "show", "uuid", c["uuid"])
		if err == nil && strings.TrimSpace(out) == ssid {
			uuids = append(uuids, c["uuid"])
		}
	}
	return uuids
}

func (m *Manager) handleWiFiToggle(json.RawMessage) (any, error) {
	next := "on"
	if m.wifiEnabled() {
		next = "off"
	}
	if _, err := runNMCLI("radio", "wifi", next); err != nil {
		return nil, err
	}
	m.broadcastSoon()
	return map[string]bool{"enabled": next == "on"}, nil
}

func (m *Manager) handleWiFiEnable(json.RawMessage) (any, error) {
	if _, err := runNMCLI("radio", "wifi", "on"); err != nil {
		return nil, err
	}
	m.broadcastSoon()
	return map[string]bool{"enabled": true}, nil
}

func (m *Manager) handleWiFiDisable(json.RawMessage) (any, error) {
	if _, err := runNMCLI("radio", "wifi", "off"); err != nil {
		return nil, err
	}
	m.broadcastSoon()
	return map[string]bool{"enabled": false}, nil
}

func (m *Manager) handleWiFiSetAutoconnect(params json.RawMessage) (any, error) {
	var p autoconnectParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	targets := m.wifiProfileUUIDs(p.SSID)
	if len(targets) == 0 {
		return nil, fmt.Errorf("saved Wi-Fi network not found")
	}
	value := "no"
	if p.Autoconnect {
		value = "yes"
	}
	for _, uuid := range targets {
		if _, err := runNMCLI("connection", "modify", "uuid", uuid, "connection.autoconnect", value); err != nil {
			return nil, err
		}
	}
	m.broadcastSoon()
	return ok("autoconnect updated"), nil
}

func (m *Manager) handleEthernetConnect(json.RawMessage) (any, error) {
	for _, c := range m.savedConnections() {
		if c["type"] == "802-3-ethernet" {
			if _, err := runNMCLI("connection", "up", "uuid", c["uuid"]); err != nil {
				return nil, err
			}
			m.broadcastSoon()
			return ok("connecting"), nil
		}
	}
	return nil, fmt.Errorf("no ethernet connection profile found")
}

func (m *Manager) handleEthernetConnectConfig(params json.RawMessage) (any, error) {
	var p uuidParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.UUID == "" {
		return nil, fmt.Errorf("uuid required")
	}
	if _, err := runNMCLI("connection", "up", "uuid", p.UUID); err != nil {
		return nil, err
	}
	m.broadcastSoon()
	return ok("connecting"), nil
}

func (m *Manager) handleEthernetDisconnect(params json.RawMessage) (any, error) {
	var p deviceParams
	_ = json.Unmarshal(params, &p)
	if p.Device != "" {
		if _, err := runNMCLI("device", "disconnect", p.Device); err != nil {
			return nil, err
		}
	} else if dev := m.state().EthernetDevice; dev != "" {
		if _, err := runNMCLI("device", "disconnect", dev); err != nil {
			return nil, err
		}
	}
	m.broadcastSoon()
	return ok("disconnected"), nil
}

func (m *Manager) handlePreferenceSet(params json.RawMessage) (any, error) {
	var p preferenceParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	switch p.Preference {
	case "auto", "wifi", "ethernet":
	default:
		return nil, fmt.Errorf("unsupported preference: %s", p.Preference)
	}
	wifiMetric, ethernetMetric := "100", "100"
	if p.Preference == "wifi" {
		wifiMetric = "50"
	}
	if p.Preference == "ethernet" {
		ethernetMetric = "50"
	}
	var errs []string
	for _, c := range m.savedConnections() {
		var err error
		switch c["type"] {
		case "802-11-wireless":
			_, err = runNMCLI("connection", "modify", "uuid", c["uuid"], "ipv4.route-metric", wifiMetric, "ipv6.route-metric", wifiMetric)
		case "802-3-ethernet":
			_, err = runNMCLI("connection", "modify", "uuid", c["uuid"], "ipv4.route-metric", ethernetMetric, "ipv6.route-metric", ethernetMetric)
		}
		if err != nil {
			errs = append(errs, fmt.Sprintf("%s: %s", c["name"], err))
		}
	}
	m.mu.Lock()
	m.preference = p.Preference
	m.mu.Unlock()
	m.broadcastSoon()
	if len(errs) > 0 {
		return nil, fmt.Errorf("set preference %s: %s", p.Preference, strings.Join(errs, "; "))
	}
	return map[string]string{"preference": p.Preference}, nil
}

func (m *Manager) handleNetworkInfo(params json.RawMessage) (any, error) {
	var p ssidParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	bands := []map[string]any{}
	// Per-band info needs the raw scan rows: state().WiFiNetworks is deduped
	// to one entry per SSID, which would collapse a dual-band AP to one band.
	for _, n := range wifiNetworksRaw() {
		if n.SSID == p.SSID {
			bands = append(bands, map[string]any{
				"ssid": n.SSID, "bssid": n.BSSID, "signal": n.Signal, "secured": n.Secured,
				"saved": n.Saved, "connected": n.Connected, "frequency": n.Frequency,
				"mode": n.Mode, "rate": n.Rate, "channel": n.Channel,
			})
		}
	}
	return map[string]any{"ssid": p.SSID, "bands": bands}, nil
}

func (m *Manager) handleEthernetInfo(params json.RawMessage) (any, error) {
	var p uuidParams
	_ = json.Unmarshal(params, &p)
	st := m.state()
	dev := st.EthernetDevice
	for _, c := range st.WiredConnections {
		if c.UUID == p.UUID && c.IsActive && st.EthernetDevice != "" {
			dev = st.EthernetDevice
		}
	}
	info := deviceDetails(dev)
	return map[string]any{
		"iface":  dev,
		"driver": info["driver"],
		"hwAddr": info["hwaddr"],
		"speed":  toInt(info["speed"]),
		"IPv4s": map[string]any{
			"ips":     splitNonEmpty(info["ip4.address"]),
			"gateway": info["ip4.gateway"],
			"dns":     info["ip4.dns"],
		},
		"IPv6s": map[string]any{
			"ips":     splitNonEmpty(info["ip6.address"]),
			"gateway": info["ip6.gateway"],
			"dns":     info["ip6.dns"],
		},
	}, nil
}

func (m *Manager) handleVPNProfiles(json.RawMessage) (any, error) {
	return m.vpnProfiles(), nil
}

func (m *Manager) handleVPNActive(json.RawMessage) (any, error) {
	return m.vpnActive(), nil
}

func (m *Manager) handleVPNConnect(params json.RawMessage) (any, error) {
	var p uuidParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	target := firstNonEmpty(p.UUIDOrName, p.UUID, p.Name)
	if target == "" {
		return nil, fmt.Errorf("uuidOrName required")
	}
	if _, err := runNMCLI("connection", "up", target); err != nil {
		return nil, err
	}
	m.broadcastSoon()
	return ok("VPN connection initiated"), nil
}

func (m *Manager) handleVPNDisconnect(params json.RawMessage) (any, error) {
	var p uuidParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	target := firstNonEmpty(p.UUIDOrName, p.UUID, p.Name)
	if target == "" {
		return nil, fmt.Errorf("uuidOrName required")
	}
	if _, err := runNMCLI("connection", "down", target); err != nil {
		return nil, err
	}
	m.broadcastSoon()
	return ok("VPN disconnected"), nil
}

func (m *Manager) handleVPNDisconnectAll(json.RawMessage) (any, error) {
	var errs []string
	for _, active := range m.vpnActive() {
		if _, err := runNMCLI("connection", "down", active.UUID); err != nil {
			errs = append(errs, fmt.Sprintf("%s: %s", active.Name, err))
		}
	}
	m.broadcastSoon()
	if len(errs) > 0 {
		return nil, fmt.Errorf("disconnect VPNs: %s", strings.Join(errs, "; "))
	}
	return ok("All VPNs disconnected"), nil
}

func (m *Manager) handleVPNPlugins(json.RawMessage) (any, error) {
	return []map[string]any{
		{"name": "OpenVPN", "serviceType": "org.freedesktop.NetworkManager.openvpn", "fileExtensions": []string{".ovpn"}},
		{"name": "WireGuard", "serviceType": "wireguard", "fileExtensions": []string{".conf"}},
	}, nil
}

func (m *Manager) handleVPNImport(params json.RawMessage) (any, error) {
	var p vpnImportParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if !filepath.IsAbs(p.File) {
		return nil, fmt.Errorf("VPN import path must be absolute")
	}
	if _, err := os.Stat(p.File); err != nil {
		return nil, err
	}
	typ := "wireguard"
	if strings.EqualFold(filepath.Ext(p.File), ".ovpn") {
		typ = "openvpn"
	}
	out, err := runNMCLI("connection", "import", "type", typ, "file", p.File)
	if err != nil {
		return nil, err
	}
	if p.Name != "" {
		name := importedConnectionName(out)
		if name != "" {
			_, _ = runNMCLI("connection", "modify", name, "connection.id", p.Name)
		}
	}
	m.broadcastSoon()
	return map[string]any{"success": true, "name": firstNonEmpty(p.Name, importedConnectionName(out))}, nil
}

func (m *Manager) handleVPNGetConfig(params json.RawMessage) (any, error) {
	var p uuidParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	target := firstNonEmpty(p.UUID, p.UUIDOrName, p.Name)
	if target == "" {
		return nil, fmt.Errorf("uuid required")
	}
	props := connectionProperties(target)
	return map[string]any{
		"uuid":        props["connection.uuid"],
		"name":        props["connection.id"],
		"type":        props["connection.type"],
		"serviceType": props["vpn.service-type"],
		"autoconnect": props["connection.autoconnect"] == "yes",
		"data":        props,
	}, nil
}

func (m *Manager) handleVPNUpdateConfig(params json.RawMessage) (any, error) {
	var p vpnUpdateParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.UUID == "" {
		return nil, fmt.Errorf("uuid required")
	}
	args := []string{"connection", "modify", "uuid", p.UUID}
	if p.Name != "" {
		args = append(args, "connection.id", p.Name)
	}
	if p.Autoconnect != nil {
		value := "no"
		if *p.Autoconnect {
			value = "yes"
		}
		args = append(args, "connection.autoconnect", value)
	}
	if len(args) == 4 {
		return ok("VPN configuration unchanged"), nil
	}
	if _, err := runNMCLI(args...); err != nil {
		return nil, err
	}
	m.broadcastSoon()
	return ok("VPN configuration updated"), nil
}

func (m *Manager) handleVPNDelete(params json.RawMessage) (any, error) {
	var p uuidParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	target := firstNonEmpty(p.UUID, p.UUIDOrName, p.Name)
	if target == "" {
		return nil, fmt.Errorf("uuid required")
	}
	if _, err := runNMCLI("connection", "delete", target); err != nil {
		return nil, err
	}
	m.broadcastSoon()
	return ok("VPN deleted"), nil
}

func (m *Manager) handleVPNSetCredentials(params json.RawMessage) (any, error) {
	var p vpnCredentialsParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.UUID == "" {
		return nil, fmt.Errorf("uuid required")
	}
	if p.Username != "" {
		if _, err := runNMCLI("connection", "modify", "uuid", p.UUID, "vpn.user-name", p.Username); err != nil {
			return nil, err
		}
	}
	if p.Password != "" {
		if _, err := runNMCLI("connection", "modify", "uuid", p.UUID, "+vpn.secrets", "password="+p.Password); err != nil {
			return nil, err
		}
	}
	return ok("VPN credentials saved"), nil
}

func (m *Manager) handleVPNClearCredentials(params json.RawMessage) (any, error) {
	var p uuidParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	target := firstNonEmpty(p.UUID, p.UUIDOrName, p.Name)
	if target == "" {
		return nil, fmt.Errorf("uuid required")
	}
	if _, err := runNMCLI("connection", "modify", target, "vpn.secrets", ""); err != nil {
		return nil, err
	}
	return ok("VPN credentials cleared"), nil
}

// state is the best-effort variant of stateChecked, for callers with no error
// channel (snapshots, helper lookups); failures are logged inside the helpers.
func (m *Manager) state() networkState {
	st, _ := m.stateChecked()
	return st
}

// stateChecked returns an error when the core device query fails (NetworkManager
// restarting, nmcli timing out) so callers do not treat an all-empty
// "disconnected, radio off" state as truth.
func (m *Manager) stateChecked() (networkState, error) {
	deviceRows, devErr := nmRowsErr([]string{"DEVICE", "TYPE", "STATE", "CONNECTION"}, "device", "status")
	devices := deviceRowMaps(deviceRows)
	m.mu.Lock()
	preference := m.preference
	m.mu.Unlock()
	conns := m.savedConnections()
	active := activeConnections()
	wifiEnabled := m.wifiEnabled()
	wifiNetworks := wifiNetworks()
	savedWifi := mergeSavedWiFi(conns, wifiNetworks)

	st := networkState{
		Backend:           "networkmanager",
		NetworkStatus:     "disconnected",
		Preference:        preference,
		WiFiEnabled:       wifiEnabled,
		WiFiNetworks:      wifiNetworks,
		SavedWiFiNetworks: savedWifi,
		VPNProfiles:       m.vpnProfilesFrom(conns),
		VPNActive:         m.vpnActiveFrom(active),
		EthernetDevices:   []ethernetDevice{},
		WiFiDevices:       []wifiDevice{},
		WiredConnections:  []wiredConn{},
	}

	activeUUIDByName := map[string]string{}
	for _, a := range active {
		activeUUIDByName[a["name"]] = a["uuid"]
	}
	for _, d := range devices {
		name, typ, state, connection := d["device"], d["type"], d["state"], d["connection"]
		details := deviceDetails(name)
		connected := strings.HasPrefix(state, "connected")
		switch typ {
		case "ethernet":
			ed := ethernetDevice{
				Name: name, HwAddress: details["hwaddr"], State: state, Connected: connected,
				IP: firstIP(details["ip4.address"]), Speed: toInt(details["speed"]), Driver: details["driver"],
			}
			st.EthernetDevices = append(st.EthernetDevices, ed)
			if connected && st.EthernetDevice == "" {
				st.EthernetDevice = name
				st.EthernetIP = ed.IP
				st.EthernetConnected = true
				st.EthernetConnectionUUID = activeUUIDByName[connection]
				st.PrimaryConnection = connection
				st.NetworkStatus = "ethernet"
			}
		case "wifi":
			wd := wifiDevice{
				Name: name, HwAddress: details["hwaddr"], State: state, Connected: connected,
				IP: firstIP(details["ip4.address"]), Networks: networksForDevice(wifiNetworks, name),
			}
			if connected {
				for _, n := range wifiNetworks {
					if n.Connected && (n.Device == "" || n.Device == name) {
						wd.SSID, wd.BSSID, wd.Signal = n.SSID, n.BSSID, n.Signal
						st.WiFiSSID, st.WiFiBSSID, st.WiFiSignal = n.SSID, n.BSSID, n.Signal
						break
					}
				}
			}
			st.WiFiDevices = append(st.WiFiDevices, wd)
			if st.WiFiDevice == "" {
				st.WiFiDevice = name
				st.WiFiDevicePath = name
			}
			if connected {
				st.WiFiDevice = name
				st.WiFiDevicePath = name
				st.WiFiIP = wd.IP
				st.WiFiConnected = true
				st.WiFiConnectionUUID = activeUUIDByName[connection]
				if !st.EthernetConnected {
					st.PrimaryConnection = connection
					st.NetworkStatus = "wifi"
				}
			}
		}
	}

	for _, c := range conns {
		if c["type"] == "802-3-ethernet" {
			st.WiredConnections = append(st.WiredConnections, wiredConn{
				ID: c["name"], UUID: c["uuid"], Type: c["type"], IsActive: activeUUIDByName[c["name"]] == c["uuid"],
			})
		}
	}
	sort.Slice(st.WiredConnections, func(i, j int) bool { return st.WiredConnections[i].ID < st.WiredConnections[j].ID })
	if len(st.VPNActive) > 0 {
		st.NetworkStatus = "vpn"
	}
	if st.WiFiNetworks == nil {
		st.WiFiNetworks = []wifiNetwork{}
	}
	if st.SavedWiFiNetworks == nil {
		st.SavedWiFiNetworks = []wifiNetwork{}
	}
	if st.VPNProfiles == nil {
		st.VPNProfiles = []vpnProfile{}
	}
	if st.VPNActive == nil {
		st.VPNActive = []vpnActive{}
	}
	if devErr != nil {
		return st, fmt.Errorf("device status: %w", devErr)
	}
	return st, nil
}

func (m *Manager) wifiEnabled() bool {
	out, err := runNMCLI("radio", "wifi")
	if err != nil {
		m.log.Warn("wifi radio state query failed", "err", err)
		return false
	}
	return strings.TrimSpace(out) == "enabled"
}

func (m *Manager) savedConnections() []map[string]string {
	rows := nmRows([]string{"NAME", "UUID", "TYPE", "AUTOCONNECT"}, "connection", "show")
	var out []map[string]string
	for _, r := range rows {
		out = append(out, map[string]string{
			"name": r[0], "uuid": r[1], "type": r[2], "autoconnect": r[3],
		})
	}
	return out
}

func (m *Manager) vpnProfiles() []vpnProfile {
	profiles := m.vpnProfilesFrom(m.savedConnections())
	if profiles == nil {
		return []vpnProfile{}
	}
	return profiles
}

func (m *Manager) vpnProfilesFrom(conns []map[string]string) []vpnProfile {
	var out []vpnProfile
	for _, c := range conns {
		if !isVPNType(c["type"]) {
			continue
		}
		props := connectionProperties(c["uuid"])
		serviceType := firstNonEmpty(props["vpn.service-type"], c["type"])
		out = append(out, vpnProfile{
			Name: c["name"], UUID: c["uuid"], Type: c["type"], ServiceType: serviceType,
			TypeLabel: labelForVPN(serviceType, c["type"]), Autoconnect: c["autoconnect"] == "yes", Data: props,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (m *Manager) vpnActive() []vpnActive {
	active := m.vpnActiveFrom(activeConnections())
	if active == nil {
		return []vpnActive{}
	}
	return active
}

func (m *Manager) vpnActiveFrom(active []map[string]string) []vpnActive {
	var out []vpnActive
	for _, a := range active {
		if !isVPNType(a["type"]) {
			continue
		}
		props := connectionProperties(a["uuid"])
		serviceType := firstNonEmpty(props["vpn.service-type"], a["type"])
		out = append(out, vpnActive{
			Name: a["name"], UUID: a["uuid"], Type: a["type"], Device: a["device"], State: "activated",
			ServiceType: serviceType, Data: props,
		})
	}
	return out
}

func (m *Manager) monitor() {
	for {
		ctx, cancel := context.WithCancel(context.Background())
		cmd := exec.CommandContext(ctx, "nmcli", "monitor")
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			// Without the monitor, live network updates are gone for the rest
			// of the session; that must not be invisible.
			m.log.Error("nmcli monitor pipe failed; live network updates disabled", "err", err)
			cancel()
			return
		}
		if err := cmd.Start(); err != nil {
			m.log.Warn("nmcli monitor start failed; retrying in 15s", "err", err)
			cancel()
			select {
			case <-m.stop:
				return
			case <-time.After(15 * time.Second):
				continue
			}
		}
		done := make(chan struct{})
		go func() {
			sc := bufio.NewScanner(stdout)
			for sc.Scan() {
				m.broadcastSoon()
			}
			close(done)
		}()
		select {
		case <-m.stop:
			cancel()
			_ = cmd.Wait()
			return
		case <-done:
			cancel()
			_ = cmd.Wait()
			time.Sleep(2 * time.Second)
		}
	}
}

// broadcastSoon requests a debounced state broadcast. The kick channel holds at
// most one pending request, so a burst of monitor events collapses into one
// recomputation instead of a goroutine (and a ~10-nmcli sweep) per event, and
// broadcastLoop serializes the sweeps so an older snapshot can never be
// broadcast after a newer one.
func (m *Manager) broadcastSoon() {
	select {
	case m.kick <- struct{}{}:
	default:
	}
}

func (m *Manager) broadcastLoop() {
	for {
		select {
		case <-m.stop:
			return
		case <-m.kick:
		}
		// Let the burst that follows a monitor event settle before the sweep.
		select {
		case <-m.stop:
			return
		case <-time.After(250 * time.Millisecond):
		}
		st, err := m.stateChecked()
		if err != nil {
			// Keep the subscribers' last-known state instead of broadcasting
			// an all-empty snapshot as truth.
			m.log.Warn("network state refresh failed, skipping broadcast", "err", err)
			continue
		}
		m.srv.Broadcast("network", st)
	}
}

// validateSSID rejects SSIDs that cannot be passed safely as positional nmcli
// argv: SSIDs come from AP beacons (attacker-controlled radio data), and a
// leading '-' would land in option position.
func validateSSID(ssid string) error {
	if ssid == "" {
		return fmt.Errorf("ssid required")
	}
	if strings.HasPrefix(ssid, "-") {
		return fmt.Errorf("unsupported ssid: leading '-' would be parsed as an nmcli option")
	}
	if strings.ContainsAny(ssid, "\x00\r\n") {
		return fmt.Errorf("invalid ssid")
	}
	return nil
}

func (m *Manager) connectWiFi(p connectWiFiParams) error {
	if err := validateSSID(p.SSID); err != nil {
		return err
	}
	if p.Username != "" {
		return m.connectEnterpriseWiFi(p)
	}
	args := []string{"device", "wifi", "connect", p.SSID}
	if p.Password != "" {
		args = append(args, "password", p.Password)
	}
	if p.Device != "" {
		args = append(args, "ifname", p.Device)
	}
	if p.Hidden {
		args = append(args, "hidden", "yes")
	}
	_, err := runNMCLI(args...)
	return err
}

func (m *Manager) connectEnterpriseWiFi(p connectWiFiParams) error {
	if p.Password == "" {
		return fmt.Errorf("enterprise Wi-Fi password required")
	}
	ifname := p.Device
	if ifname == "" {
		ifname = "*"
	}
	// Reuse an existing profile in place. Deleting it first would destroy
	// externally-configured 802-1x settings (CA certificate, EAP method) with
	// no way back when the replacement fails to connect (e.g. bad password).
	exists := false
	for _, c := range m.savedConnections() {
		if c["type"] == "802-11-wireless" && c["name"] == p.SSID {
			exists = true
			break
		}
	}
	if !exists {
		if _, err := runNMCLI("connection", "add", "type", "wifi", "ifname", ifname, "con-name", p.SSID, "ssid", p.SSID); err != nil {
			return err
		}
	}
	args := []string{
		"connection", "modify", p.SSID,
		"wifi-sec.key-mgmt", "wpa-eap",
		"802-1x.eap", "peap",
		"802-1x.phase2-auth", "mschapv2",
		"802-1x.identity", p.Username,
		"802-1x.password", p.Password,
	}
	if p.AnonymousIdentity != "" {
		args = append(args, "802-1x.anonymous-identity", p.AnonymousIdentity)
	}
	if p.DomainSuffixMatch != "" {
		args = append(args, "802-1x.domain-suffix-match", p.DomainSuffixMatch)
	}
	if _, err := runNMCLI(args...); err != nil {
		return err
	}
	_, err := runNMCLI("connection", "up", p.SSID)
	return err
}

func deviceRowMaps(rows [][]string) []map[string]string {
	var out []map[string]string
	for _, r := range rows {
		out = append(out, map[string]string{"device": r[0], "type": r[1], "state": r[2], "connection": r[3]})
	}
	return out
}

func activeConnections() []map[string]string {
	rows := nmRows([]string{"NAME", "UUID", "TYPE", "DEVICE"}, "connection", "show", "--active")
	var out []map[string]string
	for _, r := range rows {
		out = append(out, map[string]string{"name": r[0], "uuid": r[1], "type": r[2], "device": r[3]})
	}
	return out
}

// wifiNetworksRaw returns one entry per scan row (per BSSID/band), undeduped.
func wifiNetworksRaw() []wifiNetwork {
	rows := nmRows([]string{"IN-USE", "SSID", "BSSID", "SIGNAL", "SECURITY", "FREQ", "RATE", "CHAN", "MODE", "DEVICE"}, "device", "wifi", "list", "--rescan", "no")
	saved := savedWiFiMap()
	var out []wifiNetwork
	for _, r := range rows {
		ssid := r[1]
		if ssid == "" {
			continue
		}
		security := r[4]
		out = append(out, wifiNetwork{
			SSID: ssid, BSSID: r[2], Signal: toInt(r[3]), Secured: security != "" && security != "--",
			Enterprise: strings.Contains(strings.ToUpper(security), "802.1X") || strings.Contains(strings.ToUpper(security), "EAP"),
			Connected:  r[0] == "*", Saved: saved[ssid]["saved"] == "true", Autoconnect: saved[ssid]["autoconnect"] == "yes",
			Frequency: toMHz(r[5]), Rate: toRate(r[6]), Channel: toInt(r[7]), Mode: r[8], Device: r[9],
		})
	}
	return out
}

func wifiNetworks() []wifiNetwork {
	bySSID := map[string]wifiNetwork{}
	for _, n := range wifiNetworksRaw() {
		if old, ok := bySSID[n.SSID]; !ok || n.Connected || n.Signal > old.Signal {
			bySSID[n.SSID] = n
		}
	}
	out := make([]wifiNetwork, 0, len(bySSID))
	for _, n := range bySSID {
		out = append(out, n)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Connected != out[j].Connected {
			return out[i].Connected
		}
		return out[i].Signal > out[j].Signal
	})
	return out
}

func savedWiFiMap() map[string]map[string]string {
	out := map[string]map[string]string{}
	rows := nmRows([]string{"NAME", "UUID", "TYPE", "AUTOCONNECT"}, "connection", "show")
	for _, r := range rows {
		if r[2] != "802-11-wireless" {
			continue
		}
		out[r[0]] = map[string]string{"saved": "true", "uuid": r[1], "autoconnect": r[3]}
	}
	return out
}

func mergeSavedWiFi(conns []map[string]string, visible []wifiNetwork) []wifiNetwork {
	visibleBySSID := map[string]wifiNetwork{}
	for _, n := range visible {
		visibleBySSID[n.SSID] = n
	}
	seen := map[string]bool{}
	var saved []wifiNetwork
	for _, c := range conns {
		if c["type"] != "802-11-wireless" || seen[c["name"]] {
			continue
		}
		seen[c["name"]] = true
		n, ok := visibleBySSID[c["name"]]
		if !ok {
			n = wifiNetwork{SSID: c["name"], OutOfRange: true}
		}
		n.Saved = true
		n.Autoconnect = c["autoconnect"] == "yes"
		saved = append(saved, n)
	}
	sort.Slice(saved, func(i, j int) bool { return saved[i].SSID < saved[j].SSID })
	return saved
}

func networksForDevice(networks []wifiNetwork, device string) []wifiNetwork {
	out := []wifiNetwork{}
	for _, n := range networks {
		if n.Device == "" || n.Device == device {
			out = append(out, n)
		}
	}
	return out
}

func deviceDetails(device string) map[string]string {
	if device == "" {
		return map[string]string{}
	}
	out, err := runNMCLI("-t", "-f", "GENERAL.HWADDR,GENERAL.DRIVER,CAPABILITIES.SPEED,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP6.ADDRESS,IP6.GATEWAY,IP6.DNS", "device", "show", device)
	if err != nil {
		return map[string]string{}
	}
	result := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		parts := splitEscaped(line, ':')
		if len(parts) < 2 {
			continue
		}
		key := strings.ToLower(parts[0])
		key = strings.Split(key, "[")[0]
		key = strings.TrimPrefix(key, "general.")
		key = strings.TrimPrefix(key, "capabilities.") // CAPABILITIES.SPEED -> "speed"
		value := strings.Join(parts[1:], ":")
		if existing := result[key]; existing != "" {
			result[key] = existing + ", " + value
		} else {
			result[key] = value
		}
	}
	return result
}

func connectionProperties(target string) map[string]string {
	out, err := runNMCLI("-t", "connection", "show", target)
	if err != nil {
		return map[string]string{}
	}
	props := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		parts := splitEscaped(line, ':')
		if len(parts) >= 2 {
			props[strings.ToLower(parts[0])] = strings.Join(parts[1:], ":")
		}
	}
	return props
}

// nmRows is the best-effort variant of nmRowsErr: failures are logged (the
// query args are read-only nmcli commands, never secrets) and yield nil rows.
func nmRows(fields []string, args ...string) [][]string {
	rows, err := nmRowsErr(fields, args...)
	if err != nil {
		slog.Warn("nmcli query failed", "args", strings.Join(args, " "), "err", err)
		return nil
	}
	return rows
}

func nmRowsErr(fields []string, args ...string) ([][]string, error) {
	full := append([]string{"-t", "-f", strings.Join(fields, ",")}, args...)
	out, err := runNMCLI(full...)
	if err != nil {
		return nil, err
	}
	var rows [][]string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line == "" {
			continue
		}
		row := splitEscaped(line, ':')
		for len(row) < len(fields) {
			row = append(row, "")
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func runNMCLI(args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), commandTimeout)
	defer cancel()
	cmd := execbound.Command(ctx, "nmcli", args...)
	out, err := cmd.CombinedOutput()
	text := strings.TrimSpace(string(out))
	if ctx.Err() == context.DeadlineExceeded {
		return text, fmt.Errorf("nmcli timed out")
	}
	if err != nil {
		if text != "" {
			return text, fmt.Errorf("%s", text)
		}
		return text, err
	}
	return text, nil
}

func splitEscaped(s string, sep rune) []string {
	var out []string
	var b strings.Builder
	escaped := false
	for _, r := range s {
		if escaped {
			b.WriteRune(r)
			escaped = false
			continue
		}
		if r == '\\' {
			escaped = true
			continue
		}
		if r == sep {
			out = append(out, b.String())
			b.Reset()
			continue
		}
		b.WriteRune(r)
	}
	if escaped {
		b.WriteRune('\\')
	}
	out = append(out, b.String())
	return out
}

func isVPNType(t string) bool {
	t = strings.ToLower(t)
	return t == "vpn" || t == "wireguard"
}

func labelForVPN(serviceType, typ string) string {
	lower := strings.ToLower(serviceType + " " + typ)
	switch {
	case strings.Contains(lower, "openvpn"):
		return "OpenVPN"
	case strings.Contains(lower, "wireguard"):
		return "WireGuard"
	case strings.Contains(lower, "openconnect"):
		return "OpenConnect"
	default:
		return firstNonEmpty(serviceType, typ, "VPN")
	}
}

func networkEnterprise(networks []wifiNetwork, ssid string) bool {
	for _, n := range networks {
		if n.SSID == ssid {
			return n.Enterprise
		}
	}
	return false
}

func importedConnectionName(out string) string {
	if idx := strings.LastIndex(out, "'"); idx > 0 {
		before := out[:idx]
		if start := strings.LastIndex(before, "'"); start >= 0 {
			return before[start+1:]
		}
	}
	return ""
}

func tokenForSSID(ssid string) string {
	return fmt.Sprintf("wifi-%d-%s", time.Now().UnixNano(), strings.NewReplacer(" ", "_", "/", "_").Replace(ssid))
}

func ok(message string) map[string]any {
	return okResult(true, message)
}

func okResult(success bool, message string) map[string]any {
	return map[string]any{"success": success, "message": message}
}

func firstIP(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	first := strings.Split(value, ",")[0]
	first = strings.TrimSpace(first)
	if ip, _, err := net.ParseCIDR(first); err == nil {
		return ip.String()
	}
	if ip := net.ParseIP(first); ip != nil {
		return ip.String()
	}
	return strings.Split(first, "/")[0]
}

func splitNonEmpty(value string) []string {
	var out []string
	for _, item := range strings.Split(value, ",") {
		item = strings.TrimSpace(item)
		if item != "" {
			out = append(out, firstIP(item))
		}
	}
	return out
}

func toInt(s string) int {
	s = strings.TrimSpace(strings.TrimSuffix(s, " Mb/s"))
	i, _ := strconv.Atoi(s)
	return i
}

func toMHz(s string) int {
	s = strings.TrimSpace(strings.TrimSuffix(s, " MHz"))
	return toInt(s)
}

func toRate(s string) int {
	fields := strings.Fields(s)
	if len(fields) == 0 {
		return 0
	}
	return toInt(fields[0])
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return strings.TrimSpace(v)
		}
	}
	return ""
}
