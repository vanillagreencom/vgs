package bluez

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/introspect"

	"vshell/backend/internal/server"
)

const (
	bluezDest       = "org.bluez"
	adapterIface    = "org.bluez.Adapter1"
	deviceIface     = "org.bluez.Device1"
	agentIface      = "org.bluez.Agent1"
	agentMgrIface   = "org.bluez.AgentManager1"
	objectMgrIface  = "org.freedesktop.DBus.ObjectManager"
	propsIface      = "org.freedesktop.DBus.Properties"
	agentPath       = "/com/vanillagreen/vshell/bluez/agent"
	agentCapability = "KeyboardDisplay"
)

type Manager struct {
	srv *server.Server
	log *slog.Logger

	conn        *dbus.Conn
	adapterPath dbus.ObjectPath
	agent       *agent

	mu      sync.Mutex
	pending map[string]chan promptReply
	// currentPrompt is the token of the newest agent-initiated prompt; BlueZ's
	// Agent1.Cancel means "cancel the current request", never every pending
	// one (concurrent pairings must not reject each other).
	currentPrompt string
	lastState     State

	stop chan struct{}
	// kick coalesces D-Bus signal bursts (RSSI churn during discovery) into
	// single-flight state broadcasts; see broadcastLoop.
	kick chan struct{}
}

type State struct {
	Powered          bool     `json:"powered"`
	Discovering      bool     `json:"discovering"`
	Devices          []Device `json:"devices"`
	PairedDevices    []Device `json:"pairedDevices"`
	ConnectedDevices []Device `json:"connectedDevices"`
}

type Device struct {
	Path          string `json:"path"`
	Address       string `json:"address"`
	Name          string `json:"name"`
	Alias         string `json:"alias"`
	Paired        bool   `json:"paired"`
	Trusted       bool   `json:"trusted"`
	Blocked       bool   `json:"blocked"`
	Connected     bool   `json:"connected"`
	Class         uint32 `json:"class"`
	Icon          string `json:"icon"`
	RSSI          int16  `json:"rssi"`
	LegacyPairing bool   `json:"legacyPairing"`
}

type pairingPrompt struct {
	Token       string   `json:"token"`
	DevicePath  string   `json:"devicePath"`
	DeviceName  string   `json:"deviceName"`
	DeviceAddr  string   `json:"deviceAddr"`
	RequestType string   `json:"requestType"`
	Fields      []string `json:"fields"`
	Hints       []string `json:"hints"`
	Passkey     *uint32  `json:"passkey,omitempty"`
}

type promptReply struct {
	Secrets map[string]string `json:"secrets"`
	Accept  bool              `json:"accept"`
	Cancel  bool              `json:"cancel"`
}

type deviceParams struct {
	Device string `json:"device"`
}

type poweredParams struct {
	Powered bool `json:"powered"`
}

type pairingSubmitParams struct {
	Token   string            `json:"token"`
	Secrets map[string]string `json:"secrets"`
	Accept  bool              `json:"accept"`
}

type pairingCancelParams struct {
	Token string `json:"token"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	if log == nil {
		log = slog.Default()
	}
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return nil, fmt.Errorf("connect system bus: %w", err)
	}
	m := &Manager{
		srv:       srv,
		log:       log,
		conn:      conn,
		pending:   map[string]chan promptReply{},
		lastState: State{Devices: []Device{}, PairedDevices: []Device{}, ConnectedDevices: []Device{}},
		stop:      make(chan struct{}),
		kick:      make(chan struct{}, 1),
	}
	adapter, err := m.findAdapter()
	if err != nil {
		conn.Close()
		return nil, err
	}
	m.adapterPath = adapter
	m.agent = &agent{manager: m}
	if err := m.registerAgent(); err != nil {
		conn.Close()
		return nil, err
	}
	if err := m.watchSignals(); err != nil {
		m.log.Warn("bluez signal watch unavailable", "err", err)
	}

	for method, handler := range map[string]server.HandlerFunc{
		"bluetooth.getState":       m.handleGetState,
		"bluetooth.startDiscovery": m.handleStartDiscovery,
		"bluetooth.stopDiscovery":  m.handleStopDiscovery,
		"bluetooth.setPowered":     m.handleSetPowered,
		"bluetooth.pair":           m.handlePair,
		"bluetooth.connect":        m.handleConnect,
		"bluetooth.disconnect":     m.handleDisconnect,
		"bluetooth.remove":         m.handleRemove,
		"bluetooth.trust":          m.handleTrust,
		"bluetooth.untrust":        m.handleUntrust,
		"bluetooth.pairing.submit": m.handlePairingSubmit,
		"bluetooth.pairing.cancel": m.handlePairingCancel,
	} {
		srv.Register("bluetooth", method, handler)
	}
	srv.RegisterSnapshot("bluetooth", func() any { return m.GetState() })
	go m.broadcastLoop()
	return m, nil
}

func (m *Manager) Close() {
	close(m.stop)
	if m.conn == nil {
		return
	}
	_ = m.conn.Object(bluezDest, dbus.ObjectPath("/org/bluez")).Call(agentMgrIface+".UnregisterAgent", 0, dbus.ObjectPath(agentPath)).Err
	m.conn.Close()
}

func (m *Manager) findAdapter() (dbus.ObjectPath, error) {
	objects, err := m.managedObjects()
	if err != nil {
		return "", err
	}
	for path, ifaces := range objects {
		if _, ok := ifaces[adapterIface]; ok {
			return path, nil
		}
	}
	return "", fmt.Errorf("no bluetooth adapter found")
}

func (m *Manager) registerAgent() error {
	if err := m.conn.Export(m.agent, dbus.ObjectPath(agentPath), agentIface); err != nil {
		return err
	}
	node := &introspect.Node{
		Name: agentPath,
		Interfaces: []introspect.Interface{
			introspect.IntrospectData,
			{
				Name: agentIface,
				Methods: []introspect.Method{
					{Name: "Release"},
					{Name: "RequestPinCode", Args: []introspect.Arg{{Name: "device", Type: "o", Direction: "in"}, {Name: "pincode", Type: "s", Direction: "out"}}},
					{Name: "RequestPasskey", Args: []introspect.Arg{{Name: "device", Type: "o", Direction: "in"}, {Name: "passkey", Type: "u", Direction: "out"}}},
					{Name: "DisplayPinCode", Args: []introspect.Arg{{Name: "device", Type: "o", Direction: "in"}, {Name: "pincode", Type: "s", Direction: "in"}}},
					{Name: "DisplayPasskey", Args: []introspect.Arg{{Name: "device", Type: "o", Direction: "in"}, {Name: "passkey", Type: "u", Direction: "in"}, {Name: "entered", Type: "q", Direction: "in"}}},
					{Name: "RequestConfirmation", Args: []introspect.Arg{{Name: "device", Type: "o", Direction: "in"}, {Name: "passkey", Type: "u", Direction: "in"}}},
					{Name: "RequestAuthorization", Args: []introspect.Arg{{Name: "device", Type: "o", Direction: "in"}}},
					{Name: "AuthorizeService", Args: []introspect.Arg{{Name: "device", Type: "o", Direction: "in"}, {Name: "uuid", Type: "s", Direction: "in"}}},
					{Name: "Cancel"},
				},
			},
		},
	}
	_ = m.conn.Export(introspect.NewIntrospectable(node), dbus.ObjectPath(agentPath), "org.freedesktop.DBus.Introspectable")
	obj := m.conn.Object(bluezDest, dbus.ObjectPath("/org/bluez"))
	if err := obj.Call(agentMgrIface+".RegisterAgent", 0, dbus.ObjectPath(agentPath), agentCapability).Err; err != nil {
		return err
	}
	if err := obj.Call(agentMgrIface+".RequestDefaultAgent", 0, dbus.ObjectPath(agentPath)).Err; err != nil {
		// Without default-agent status another agent gets the pairing
		// prompts and ours never fire; keep going, but leave a trace.
		m.log.Warn("bluez RequestDefaultAgent failed; pairing prompts may route elsewhere", "err", err)
	}
	return nil
}

func (m *Manager) watchSignals() error {
	// Sender-filtered to org.bluez: without it every PropertiesChanged on the
	// system bus (NetworkManager, UPower, logind churn) would trigger a full
	// GetManagedObjects sweep and a bluetooth broadcast.
	if err := m.conn.AddMatchSignal(dbus.WithMatchSender(bluezDest), dbus.WithMatchInterface(propsIface), dbus.WithMatchMember("PropertiesChanged")); err != nil {
		return err
	}
	if err := m.conn.AddMatchSignal(dbus.WithMatchSender(bluezDest), dbus.WithMatchInterface(objectMgrIface), dbus.WithMatchMember("InterfacesAdded")); err != nil {
		return err
	}
	if err := m.conn.AddMatchSignal(dbus.WithMatchSender(bluezDest), dbus.WithMatchInterface(objectMgrIface), dbus.WithMatchMember("InterfacesRemoved")); err != nil {
		return err
	}
	// A bluetoothd restart drops our agent registration and can change the
	// adapter path; watch the name owner so both are re-established.
	if err := m.conn.AddMatchSignal(
		dbus.WithMatchSender("org.freedesktop.DBus"),
		dbus.WithMatchInterface("org.freedesktop.DBus"),
		dbus.WithMatchMember("NameOwnerChanged"),
		dbus.WithMatchArg(0, bluezDest),
	); err != nil {
		m.log.Warn("bluez NameOwnerChanged watch unavailable; agent will not survive a bluetoothd restart", "err", err)
	}
	signals := make(chan *dbus.Signal, 128)
	m.conn.Signal(signals)
	go func() {
		for sig := range signals {
			if sig == nil {
				continue
			}
			if sig.Name == "org.freedesktop.DBus.NameOwnerChanged" && len(sig.Body) == 3 {
				name, _ := sig.Body[0].(string)
				newOwner, _ := sig.Body[2].(string)
				if name == bluezDest && newOwner != "" {
					go m.reinitialize()
				}
				continue
			}
			m.broadcastSoon()
		}
	}()
	return nil
}

// reinitialize re-discovers the adapter and re-registers the pairing agent
// after bluetoothd (re)claims its bus name. Without this, pairing prompts
// silently stop reaching the shell after `systemctl restart bluetooth`.
func (m *Manager) reinitialize() {
	var adapter dbus.ObjectPath
	var err error
	for attempt := 0; attempt < 5; attempt++ {
		if adapter, err = m.findAdapter(); err == nil {
			break
		}
		select {
		case <-m.stop:
			return
		case <-time.After(time.Second):
		}
	}
	if err != nil {
		m.log.Warn("bluez reinit: no adapter found after bluetoothd restart", "err", err)
		return
	}
	m.mu.Lock()
	m.adapterPath = adapter
	m.mu.Unlock()
	if err := m.registerAgent(); err != nil {
		m.log.Warn("bluez reinit: agent re-registration failed", "err", err)
	}
	m.broadcastSoon()
}

// GetState is the best-effort variant of GetStateChecked, for callers with no
// error channel (snapshots, broadcast helpers): a transient D-Bus failure
// returns the last known state instead of an empty powered-off one.
func (m *Manager) GetState() State {
	state, err := m.GetStateChecked()
	if err != nil {
		m.log.Warn("bluez state query failed, using last known state", "err", err)
		m.mu.Lock()
		state = m.lastState
		m.mu.Unlock()
	}
	return state
}

func (m *Manager) GetStateChecked() (State, error) {
	objects, err := m.managedObjects()
	if err != nil {
		return State{Devices: []Device{}, PairedDevices: []Device{}, ConnectedDevices: []Device{}}, err
	}
	state := State{Devices: []Device{}, PairedDevices: []Device{}, ConnectedDevices: []Device{}}
	adapterPath := m.getAdapterPath()
	if props, ok := objects[adapterPath][adapterIface]; ok {
		state.Powered = propBool(props, "Powered")
		state.Discovering = propBool(props, "Discovering")
	}
	for path, ifaces := range objects {
		props, ok := ifaces[deviceIface]
		if !ok || !strings.HasPrefix(string(path), string(adapterPath)+"/") {
			continue
		}
		dev := Device{
			Path:          string(path),
			Address:       propString(props, "Address"),
			Name:          propString(props, "Name"),
			Alias:         propString(props, "Alias"),
			Paired:        propBool(props, "Paired"),
			Trusted:       propBool(props, "Trusted"),
			Blocked:       propBool(props, "Blocked"),
			Connected:     propBool(props, "Connected"),
			Class:         propUint32(props, "Class"),
			Icon:          propString(props, "Icon"),
			RSSI:          propInt16(props, "RSSI"),
			LegacyPairing: propBool(props, "LegacyPairing"),
		}
		state.Devices = append(state.Devices, dev)
		if dev.Paired || dev.Trusted {
			state.PairedDevices = append(state.PairedDevices, dev)
		}
		if dev.Connected {
			state.ConnectedDevices = append(state.ConnectedDevices, dev)
		}
	}
	m.mu.Lock()
	m.lastState = state
	m.mu.Unlock()
	return state, nil
}

func (m *Manager) managedObjects() (map[dbus.ObjectPath]map[string]map[string]dbus.Variant, error) {
	var objects map[dbus.ObjectPath]map[string]map[string]dbus.Variant
	err := m.conn.Object(bluezDest, dbus.ObjectPath("/")).Call(objectMgrIface+".GetManagedObjects", 0).Store(&objects)
	return objects, err
}

func (m *Manager) handleGetState(json.RawMessage) (any, error) {
	return m.GetStateChecked()
}

func (m *Manager) handleStartDiscovery(json.RawMessage) (any, error) {
	err := m.adapter().Call(adapterIface+".StartDiscovery", 0).Err
	m.broadcastSoon()
	return ok("discovery started"), err
}

func (m *Manager) handleStopDiscovery(json.RawMessage) (any, error) {
	err := m.adapter().Call(adapterIface+".StopDiscovery", 0).Err
	m.broadcastSoon()
	return ok("discovery stopped"), err
}

func (m *Manager) handleSetPowered(params json.RawMessage) (any, error) {
	var p poweredParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	err := m.adapter().Call(propsIface+".Set", 0, adapterIface, "Powered", dbus.MakeVariant(p.Powered)).Err
	m.broadcastSoon()
	return ok("powered state updated"), err
}

func (m *Manager) handlePair(params json.RawMessage) (any, error) {
	obj, err := m.deviceFromParams(params)
	if err != nil {
		return nil, err
	}
	err = obj.Call(deviceIface+".Pair", 0).Err
	m.broadcastSoon()
	return ok("pairing initiated"), err
}

func (m *Manager) handleConnect(params json.RawMessage) (any, error) {
	obj, err := m.deviceFromParams(params)
	if err != nil {
		return nil, err
	}
	err = obj.Call(deviceIface+".Connect", 0).Err
	m.broadcastSoon()
	return ok("connecting"), err
}

func (m *Manager) handleDisconnect(params json.RawMessage) (any, error) {
	obj, err := m.deviceFromParams(params)
	if err != nil {
		return nil, err
	}
	err = obj.Call(deviceIface+".Disconnect", 0).Err
	m.broadcastSoon()
	return ok("disconnected"), err
}

func (m *Manager) handleRemove(params json.RawMessage) (any, error) {
	var p deviceParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	path, err := validateDevicePath(p.Device)
	if err != nil {
		return nil, err
	}
	err = m.adapter().Call(adapterIface+".RemoveDevice", 0, path).Err
	m.broadcastSoon()
	return ok("device removed"), err
}

func (m *Manager) handleTrust(params json.RawMessage) (any, error) {
	return m.setTrust(params, true)
}

func (m *Manager) handleUntrust(params json.RawMessage) (any, error) {
	return m.setTrust(params, false)
}

func (m *Manager) setTrust(params json.RawMessage, trusted bool) (any, error) {
	obj, err := m.deviceFromParams(params)
	if err != nil {
		return nil, err
	}
	err = obj.Call(propsIface+".Set", 0, deviceIface, "Trusted", dbus.MakeVariant(trusted)).Err
	m.broadcastSoon()
	if trusted {
		return ok("device trusted"), err
	}
	return ok("device untrusted"), err
}

func (m *Manager) handlePairingSubmit(params json.RawMessage) (any, error) {
	var p pairingSubmitParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.Token == "" {
		return nil, fmt.Errorf("token required")
	}
	ch, found := m.takePending(p.Token)
	if !found {
		return nil, fmt.Errorf("pairing prompt not found")
	}
	ch <- promptReply{Secrets: p.Secrets, Accept: p.Accept}
	return ok("pairing response submitted"), nil
}

// takePending removes and returns the reply channel for token, clearing the
// current-prompt marker when it matches.
func (m *Manager) takePending(token string) (chan promptReply, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	ch, found := m.pending[token]
	if found {
		delete(m.pending, token)
		if m.currentPrompt == token {
			m.currentPrompt = ""
		}
	}
	return ch, found
}

func (m *Manager) handlePairingCancel(params json.RawMessage) (any, error) {
	var p pairingCancelParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	ch, found := m.takePending(p.Token)
	if found {
		ch <- promptReply{Cancel: true}
	}
	return ok("pairing cancelled"), nil
}

// getAdapterPath guards adapterPath, which reinitialize may rewrite after a
// bluetoothd restart.
func (m *Manager) getAdapterPath() dbus.ObjectPath {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.adapterPath
}

func (m *Manager) adapter() dbus.BusObject {
	return m.conn.Object(bluezDest, m.getAdapterPath())
}

func (m *Manager) deviceFromParams(params json.RawMessage) (dbus.BusObject, error) {
	var p deviceParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	path, err := validateDevicePath(p.Device)
	if err != nil {
		return nil, err
	}
	return m.conn.Object(bluezDest, path), nil
}

// broadcastSoon requests a debounced state broadcast. The kick channel holds at
// most one pending request, so a burst of D-Bus signals collapses into one
// GetManagedObjects sweep instead of a goroutine per signal, and broadcastLoop
// serializes the sweeps so an older snapshot can never be broadcast after a
// newer one.
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
		// Let the signal burst settle before the sweep.
		select {
		case <-m.stop:
			return
		case <-time.After(200 * time.Millisecond):
		}
		state, err := m.GetStateChecked()
		if err != nil {
			// Keep the subscribers' last-known state instead of broadcasting
			// an empty powered-off snapshot as truth.
			m.log.Warn("bluez state refresh failed, skipping broadcast", "err", err)
			continue
		}
		m.srv.Broadcast("bluetooth", state)
	}
}

func validateDevicePath(value string) (dbus.ObjectPath, error) {
	if value == "" || strings.ContainsAny(value, "\x00\r\n") {
		return "", fmt.Errorf("device path required")
	}
	path := dbus.ObjectPath(value)
	if !path.IsValid() || !strings.HasPrefix(value, "/org/bluez/") {
		return "", fmt.Errorf("invalid bluetooth device path")
	}
	return path, nil
}

type agent struct {
	manager *Manager
}

func (a *agent) Release() *dbus.Error { return nil }

func (a *agent) RequestPinCode(device dbus.ObjectPath) (string, *dbus.Error) {
	reply, err := a.manager.prompt(device, "pin", []string{"pin"}, nil)
	if err != nil {
		return "", dbus.MakeFailedError(err)
	}
	return reply.Secrets["pin"], nil
}

func (a *agent) RequestPasskey(device dbus.ObjectPath) (uint32, *dbus.Error) {
	reply, err := a.manager.prompt(device, "passkey", []string{"passkey"}, nil)
	if err != nil {
		return 0, dbus.MakeFailedError(err)
	}
	value, err := strconv.ParseUint(reply.Secrets["passkey"], 10, 32)
	if err != nil {
		return 0, dbus.MakeFailedError(fmt.Errorf("invalid passkey"))
	}
	return uint32(value), nil
}

func (a *agent) DisplayPinCode(device dbus.ObjectPath, pincode string) *dbus.Error {
	_, err := a.manager.prompt(device, "display-pin", nil, &pincode)
	if err != nil {
		return dbus.MakeFailedError(err)
	}
	return nil
}

func (a *agent) DisplayPasskey(device dbus.ObjectPath, passkey uint32, entered uint16) *dbus.Error {
	if entered != 0 {
		return nil
	}
	_, err := a.manager.prompt(device, "display-passkey", nil, &passkey)
	if err != nil {
		return dbus.MakeFailedError(err)
	}
	return nil
}

func (a *agent) RequestConfirmation(device dbus.ObjectPath, passkey uint32) *dbus.Error {
	reply, err := a.manager.prompt(device, "confirm", []string{"decision"}, &passkey)
	if err != nil {
		return dbus.MakeFailedError(err)
	}
	if !reply.Accept && reply.Secrets["decision"] != "yes" && reply.Secrets["decision"] != "accept" {
		return dbus.NewError("org.bluez.Error.Rejected", nil)
	}
	return nil
}

func (a *agent) RequestAuthorization(device dbus.ObjectPath) *dbus.Error {
	reply, err := a.manager.prompt(device, "authorize", []string{"decision"}, nil)
	if err != nil {
		return dbus.MakeFailedError(err)
	}
	if !reply.Accept && reply.Secrets["decision"] != "yes" && reply.Secrets["decision"] != "accept" {
		return dbus.NewError("org.bluez.Error.Rejected", nil)
	}
	return nil
}

func (a *agent) AuthorizeService(device dbus.ObjectPath, uuid string) *dbus.Error {
	reply, err := a.manager.prompt(device, "authorize-service:"+uuid, []string{"decision"}, nil)
	if err != nil {
		return dbus.MakeFailedError(err)
	}
	if !reply.Accept && reply.Secrets["decision"] != "yes" && reply.Secrets["decision"] != "accept" {
		return dbus.NewError("org.bluez.Error.Rejected", nil)
	}
	return nil
}

func (a *agent) Cancel() *dbus.Error {
	m := a.manager
	m.mu.Lock()
	token := m.currentPrompt
	m.mu.Unlock()
	if ch, found := m.takePending(token); found {
		ch <- promptReply{Cancel: true}
	}
	return nil
}

func (m *Manager) prompt(device dbus.ObjectPath, requestType string, fields []string, passkey any) (promptReply, error) {
	token, err := randomToken()
	if err != nil {
		return promptReply{}, err
	}
	ch := make(chan promptReply, 1)
	m.mu.Lock()
	m.pending[token] = ch
	m.currentPrompt = token
	m.mu.Unlock()
	name, addr := m.deviceNameAddr(device)
	prompt := pairingPrompt{Token: token, DevicePath: string(device), DeviceName: name, DeviceAddr: addr, RequestType: requestType, Fields: fields, Hints: []string{}}
	switch v := passkey.(type) {
	case *string:
		if v != nil {
			prompt.Hints = []string{*v}
		}
	case *uint32:
		prompt.Passkey = v
	}
	m.srv.Broadcast("bluetooth.pairing", prompt)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	select {
	case reply := <-ch:
		if reply.Cancel {
			return reply, fmt.Errorf("pairing cancelled")
		}
		return reply, nil
	case <-ctx.Done():
		m.takePending(token)
		return promptReply{}, fmt.Errorf("pairing prompt timed out")
	}
}

func (m *Manager) deviceNameAddr(path dbus.ObjectPath) (string, string) {
	obj := m.conn.Object(bluezDest, path)
	nameVar, _ := obj.GetProperty(deviceIface + ".Name")
	addrVar, _ := obj.GetProperty(deviceIface + ".Address")
	var name, addr string
	_ = nameVar.Store(&name)
	_ = addrVar.Store(&addr)
	return name, addr
}

func randomToken() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

func ok(message string) map[string]any {
	return map[string]any{"success": true, "message": message}
}

func propString(props map[string]dbus.Variant, key string) string {
	var value string
	if v, ok := props[key]; ok {
		_ = v.Store(&value)
	}
	return value
}

func propBool(props map[string]dbus.Variant, key string) bool {
	var value bool
	if v, ok := props[key]; ok {
		_ = v.Store(&value)
	}
	return value
}

func propUint32(props map[string]dbus.Variant, key string) uint32 {
	var value uint32
	if v, ok := props[key]; ok {
		_ = v.Store(&value)
	}
	return value
}

func propInt16(props map[string]dbus.Variant, key string) int16 {
	var value int16
	if v, ok := props[key]; ok {
		_ = v.Store(&value)
	}
	return value
}
