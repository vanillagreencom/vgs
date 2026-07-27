package freedesktop

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/introspect"

	"vshell/backend/internal/server"
)

const (
	fdName       = "org.freedesktop.ScreenSaver"
	fdIface      = "org.freedesktop.ScreenSaver"
	fdPath       = "/org/freedesktop/ScreenSaver"
	fdPathCompat = "/ScreenSaver"

	gnomeName  = "org.gnome.ScreenSaver"
	gnomeIface = "org.gnome.ScreenSaver"
	gnomePath  = "/org/gnome/ScreenSaver"
)

type ScreensaverInhibitor struct {
	Cookie    uint32 `json:"cookie"`
	AppName   string `json:"appName"`
	Reason    string `json:"reason"`
	Peer      string `json:"peer"`
	StartTime int64  `json:"startTime"`
}

type ScreensaverState struct {
	Available  bool                   `json:"available"`
	Active     bool                   `json:"active"`
	Inhibited  bool                   `json:"inhibited"`
	Inhibitors []ScreensaverInhibitor `json:"inhibitors"`
}

type AccountsState struct {
	Available     bool   `json:"available"`
	UserPath      string `json:"userPath"`
	IconFile      string `json:"iconFile"`
	RealName      string `json:"realName"`
	UserName      string `json:"userName"`
	AccountType   int32  `json:"accountType"`
	HomeDirectory string `json:"homeDirectory"`
	Shell         string `json:"shell"`
	Email         string `json:"email"`
	Language      string `json:"language"`
	Location      string `json:"location"`
	Locked        bool   `json:"locked"`
	PasswordMode  int32  `json:"passwordMode"`
	UID           uint64 `json:"uid"`
}

type SettingsState struct {
	Available   bool   `json:"available"`
	ColorScheme uint32 `json:"colorScheme"`
}

type State struct {
	Accounts    AccountsState    `json:"accounts"`
	Settings    SettingsState    `json:"settings"`
	Screensaver ScreensaverState `json:"screensaver"`
}

type Manager struct {
	log *slog.Logger
	srv *server.Server

	conn       *dbus.Conn
	systemConn *dbus.Conn

	accountsObj dbus.BusObject
	settingsObj dbus.BusObject

	mu         sync.RWMutex
	state      ScreensaverState
	accounts   AccountsState
	settings   SettingsState
	cookie     atomic.Uint32
	fdOwned    bool
	gnoOwned   bool
	currentUID uint64

	lockRequestMu sync.Mutex
	onLockRequest func()
}

type handler struct {
	manager *Manager
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	if log == nil {
		log = slog.Default()
	}
	conn, sessionErr := dbus.ConnectSessionBus()
	systemConn, systemErr := dbus.ConnectSystemBus()
	if conn == nil && systemConn == nil {
		return nil, fmt.Errorf("connect freedesktop dbus: session=%v system=%v", sessionErr, systemErr)
	}
	m := &Manager{
		log:        log,
		srv:        srv,
		conn:       conn,
		systemConn: systemConn,
		currentUID: uint64(os.Getuid()),
		state: ScreensaverState{
			Available:  false,
			Inhibitors: []ScreensaverInhibitor{},
		},
	}

	if err := m.initializeAccounts(); err != nil {
		m.log.Warn("accounts service unavailable", "err", err)
	}
	if err := m.initializeSettings(); err != nil {
		m.log.Warn("portal settings unavailable", "err", err)
	}
	if conn != nil {
		h := &handler{manager: m}
		// claim exports the handler onto the bus, so a peer can invoke it (and
		// reach emitActiveChanged) before these results are stored: assign
		// under the lock the readers use.
		fdOwned := m.claim(h, fdName, fdIface, fdPath, fdPathCompat)
		gnoOwned := m.claim(h, gnomeName, gnomeIface, gnomePath)
		m.mu.Lock()
		m.fdOwned = fdOwned
		m.gnoOwned = gnoOwned
		m.mu.Unlock()
		if !fdOwned && !gnoOwned {
			m.log.Warn("screensaver bus names already owned")
		} else {
			if err := m.watchPeerDisconnects(); err != nil {
				m.log.Warn("screensaver peer watch unavailable", "err", err)
			}
			m.mu.Lock()
			m.state.Available = true
			m.mu.Unlock()
		}
	}
	srv.Register("freedesktop", "freedesktop.getState", m.handleGetState)
	srv.Register("freedesktop", "freedesktop.accounts.getUserIconFile", m.handleGetUserIconFile)
	srv.Register("freedesktop", "freedesktop.accounts.setIconFile", m.handleSetIconFile)
	srv.Register("freedesktop", "freedesktop.settings.getColorScheme", m.handleGetColorScheme)
	srv.Register("freedesktop", "freedesktop.settings.setIconTheme", m.handleSetIconTheme)
	srv.RegisterSnapshot("freedesktop", func() any { return m.GetState() })
	srv.AddCapability("freedesktop")
	srv.RegisterSnapshot("freedesktop.screensaver", func() any { return m.GetScreensaverState() })
	return m, nil
}

func (m *Manager) Close() {
	if m.conn != nil {
		m.conn.Close()
	}
	if m.systemConn != nil {
		m.systemConn.Close()
	}
}

func (m *Manager) claim(h *handler, name, iface string, paths ...dbus.ObjectPath) bool {
	if m.conn == nil {
		return false
	}
	reply, err := m.conn.RequestName(name, dbus.NameFlagDoNotQueue)
	if err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		return false
	}
	for _, path := range paths {
		if err := m.conn.Export(h, path, iface); err != nil {
			m.log.Warn("screensaver export failed", "name", name, "path", path, "err", err)
			// Keeping the name with no handler would make apps' Inhibit calls
			// fail while blocking other screensaver implementations from it.
			_, _ = m.conn.ReleaseName(name)
			return false
		}
		node := &introspect.Node{
			Name: string(path),
			Interfaces: []introspect.Interface{
				introspect.IntrospectData,
				screensaverIntrospection(iface),
			},
		}
		_ = m.conn.Export(introspect.NewIntrospectable(node), path, "org.freedesktop.DBus.Introspectable")
	}
	return true
}

func screensaverIntrospection(iface string) introspect.Interface {
	return introspect.Interface{
		Name: iface,
		Methods: []introspect.Method{
			{Name: "Inhibit", Args: []introspect.Arg{
				{Name: "application_name", Type: "s", Direction: "in"},
				{Name: "reason_for_inhibit", Type: "s", Direction: "in"},
				{Name: "cookie", Type: "u", Direction: "out"},
			}},
			{Name: "UnInhibit", Args: []introspect.Arg{
				{Name: "cookie", Type: "u", Direction: "in"},
			}},
			{Name: "GetActive", Args: []introspect.Arg{
				{Name: "active", Type: "b", Direction: "out"},
			}},
			{Name: "SetActive", Args: []introspect.Arg{
				{Name: "active", Type: "b", Direction: "in"},
			}},
			{Name: "Lock"},
		},
		Signals: []introspect.Signal{
			{Name: "ActiveChanged", Args: []introspect.Arg{{Name: "new_value", Type: "b"}}},
		},
	}
}

func (h *handler) Inhibit(sender dbus.Sender, appName, reason string) (uint32, *dbus.Error) {
	if appName == "" {
		return 0, dbus.NewError("org.freedesktop.DBus.Error.InvalidArgs", []any{"application name required"})
	}
	if reason == "" {
		return 0, dbus.NewError("org.freedesktop.DBus.Error.InvalidArgs", []any{"reason required"})
	}
	lowerReason := strings.ToLower(reason)
	if strings.Contains(lowerReason, "audio") && !strings.Contains(lowerReason, "video") {
		return 0, nil
	}
	if idx := strings.LastIndex(appName, "/"); idx >= 0 && idx < len(appName)-1 {
		appName = appName[idx+1:]
	}
	appName = filepath.Base(appName)

	cookie := h.manager.cookie.Add(1)
	inhibitor := ScreensaverInhibitor{
		Cookie:    cookie,
		AppName:   appName,
		Reason:    reason,
		Peer:      string(sender),
		StartTime: time.Now().Unix(),
	}
	h.manager.mu.Lock()
	h.manager.state.Inhibitors = append(h.manager.state.Inhibitors, inhibitor)
	h.manager.state.Inhibited = len(h.manager.state.Inhibitors) > 0
	h.manager.mu.Unlock()
	h.manager.broadcast()
	return cookie, nil
}

func (h *handler) UnInhibit(sender dbus.Sender, cookie uint32) *dbus.Error {
	h.manager.mu.Lock()
	inhibitors := h.manager.state.Inhibitors
	for i, inhibitor := range inhibitors {
		if inhibitor.Cookie == cookie {
			h.manager.state.Inhibitors = append(inhibitors[:i], inhibitors[i+1:]...)
			h.manager.state.Inhibited = len(h.manager.state.Inhibitors) > 0
			h.manager.mu.Unlock()
			h.manager.broadcast()
			return nil
		}
	}
	h.manager.mu.Unlock()
	return nil
}

func (h *handler) GetActive() (bool, *dbus.Error) {
	h.manager.mu.RLock()
	defer h.manager.mu.RUnlock()
	return h.manager.state.Active, nil
}

func (h *handler) SetActive(active bool) *dbus.Error {
	h.manager.SetScreenLockActive(active)
	return nil
}

func (h *handler) Lock() *dbus.Error {
	m := h.manager
	m.lockRequestMu.Lock()
	fn := m.onLockRequest
	m.lockRequestMu.Unlock()
	if fn != nil {
		// Lock the session for real (via logind); the resulting Lock signal
		// drives the shell's lock screen and LockedHint flows back into
		// SetScreenLockActive through the loginctl state listener. Flipping
		// only the reported flag would make apps' Lock calls silent no-ops.
		fn()
		return nil
	}
	m.SetScreenLockActive(true)
	return nil
}

// SetLockRequestHandler wires org.freedesktop.ScreenSaver.Lock to a real
// session lock (loginctl); without it Lock only flips the reported state.
func (m *Manager) SetLockRequestHandler(fn func()) {
	m.lockRequestMu.Lock()
	m.onLockRequest = fn
	m.lockRequestMu.Unlock()
}

func (m *Manager) SetScreenLockActive(active bool) {
	m.mu.Lock()
	changed := m.state.Active != active
	m.state.Active = active
	m.mu.Unlock()
	if !changed {
		return
	}
	m.emitActiveChanged(active)
	m.broadcast()
}

func (m *Manager) GetState() State {
	m.mu.RLock()
	defer m.mu.RUnlock()
	screensaver := m.state
	screensaver.Inhibitors = append([]ScreensaverInhibitor{}, m.state.Inhibitors...)
	return State{
		Accounts:    m.accounts,
		Settings:    m.settings,
		Screensaver: screensaver,
	}
}

func (m *Manager) GetScreensaverState() ScreensaverState {
	m.mu.RLock()
	defer m.mu.RUnlock()
	state := m.state
	state.Inhibitors = append([]ScreensaverInhibitor{}, m.state.Inhibitors...)
	return state
}

func (m *Manager) broadcast() {
	m.srv.Broadcast("freedesktop.screensaver", m.GetScreensaverState())
	m.srv.Broadcast("freedesktop", m.GetState())
}

func (m *Manager) emitActiveChanged(active bool) {
	if m.conn == nil {
		return
	}
	m.mu.RLock()
	fdOwned, gnoOwned := m.fdOwned, m.gnoOwned
	m.mu.RUnlock()
	if fdOwned {
		_ = m.conn.Emit(fdPath, fdIface+".ActiveChanged", active)
		_ = m.conn.Emit(fdPathCompat, fdIface+".ActiveChanged", active)
	}
	if gnoOwned {
		_ = m.conn.Emit(gnomePath, gnomeIface+".ActiveChanged", active)
	}
}

func (m *Manager) watchPeerDisconnects() error {
	if err := m.conn.AddMatchSignal(
		dbus.WithMatchInterface("org.freedesktop.DBus"),
		dbus.WithMatchMember("NameOwnerChanged"),
	); err != nil {
		return err
	}
	signals := make(chan *dbus.Signal, 64)
	m.conn.Signal(signals)
	go func() {
		for sig := range signals {
			if sig.Name != "org.freedesktop.DBus.NameOwnerChanged" || len(sig.Body) < 3 {
				continue
			}
			name, _ := sig.Body[0].(string)
			newOwner, _ := sig.Body[2].(string)
			if name == "" || newOwner != "" {
				continue
			}
			m.removeInhibitorsByPeer(name)
		}
	}()
	return nil
}

func (m *Manager) removeInhibitorsByPeer(peer string) {
	m.mu.Lock()
	changed := false
	remaining := make([]ScreensaverInhibitor, 0, len(m.state.Inhibitors))
	for _, inhibitor := range m.state.Inhibitors {
		if inhibitor.Peer == peer {
			changed = true
			continue
		}
		remaining = append(remaining, inhibitor)
	}
	if changed {
		m.state.Inhibitors = remaining
		m.state.Inhibited = len(remaining) > 0
	}
	m.mu.Unlock()
	if changed {
		m.broadcast()
	}
}

type iconFileParams struct {
	Path string `json:"path"`
}

type usernameParams struct {
	Username string `json:"username"`
}

type iconThemeParams struct {
	IconTheme string `json:"iconTheme"`
}

func (m *Manager) handleGetState(json.RawMessage) (any, error) {
	_ = m.updateAccountsState()
	_ = m.updateSettingsState()
	return m.GetState(), nil
}

func (m *Manager) handleGetUserIconFile(params json.RawMessage) (any, error) {
	var p usernameParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.Username) == "" {
		return nil, fmt.Errorf("username required")
	}
	icon, err := m.getUserIconFile(p.Username)
	if err != nil {
		return nil, err
	}
	return map[string]any{"success": true, "value": icon}, nil
}

func (m *Manager) handleSetIconFile(params json.RawMessage) (any, error) {
	var p iconFileParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := validateIconPath(p.Path); err != nil {
		return nil, err
	}
	if m.accountsObj == nil {
		return nil, fmt.Errorf("accounts service not available")
	}
	if err := m.accountsObj.Call("org.freedesktop.Accounts.User.SetIconFile", 0, p.Path).Err; err != nil {
		return nil, fmt.Errorf("set icon file: %w", err)
	}
	_ = m.updateAccountsState()
	m.srv.Broadcast("freedesktop", m.GetState())
	return map[string]any{"success": true, "message": "icon file set"}, nil
}

func (m *Manager) handleGetColorScheme(json.RawMessage) (any, error) {
	if err := m.updateSettingsState(); err != nil {
		return nil, err
	}
	m.mu.RLock()
	value := m.settings.ColorScheme
	m.mu.RUnlock()
	return map[string]uint32{"colorScheme": value}, nil
}

func (m *Manager) handleSetIconTheme(params json.RawMessage) (any, error) {
	var p iconThemeParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	theme, err := validateIconTheme(p.IconTheme)
	if err != nil {
		return nil, err
	}
	if _, err := exec.LookPath("gsettings"); err != nil {
		return nil, fmt.Errorf("gsettings not available")
	}
	out, err := exec.Command("gsettings", "set", "org.gnome.desktop.interface", "icon-theme", theme).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("set icon theme: %s", strings.TrimSpace(string(out)))
	}
	return map[string]any{"success": true, "message": "icon theme set"}, nil
}

func (m *Manager) initializeAccounts() error {
	if m.systemConn == nil {
		m.mu.Lock()
		m.accounts.Available = false
		m.mu.Unlock()
		return fmt.Errorf("system bus unavailable")
	}
	accountsManager := m.systemConn.Object("org.freedesktop.Accounts", dbus.ObjectPath("/org/freedesktop/Accounts"))
	var userPath dbus.ObjectPath
	if err := accountsManager.Call("org.freedesktop.Accounts.FindUserById", 0, int64(m.currentUID)).Store(&userPath); err != nil {
		m.mu.Lock()
		m.accounts.Available = false
		m.mu.Unlock()
		return err
	}
	m.accountsObj = m.systemConn.Object("org.freedesktop.Accounts", userPath)
	m.mu.Lock()
	m.accounts.Available = true
	m.accounts.UserPath = string(userPath)
	m.accounts.UID = m.currentUID
	m.mu.Unlock()
	return m.updateAccountsState()
}

func (m *Manager) updateAccountsState() error {
	if m.accountsObj == nil {
		return fmt.Errorf("accounts service not available")
	}
	props, err := getAllProperties(m.accountsObj, "org.freedesktop.Accounts.User")
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.accounts.Available = true
	m.accounts.IconFile = propString(props, "IconFile")
	m.accounts.RealName = propString(props, "RealName")
	m.accounts.UserName = propString(props, "UserName")
	m.accounts.AccountType = propInt32(props, "AccountType")
	m.accounts.HomeDirectory = propString(props, "HomeDirectory")
	m.accounts.Shell = propString(props, "Shell")
	m.accounts.Email = propString(props, "Email")
	m.accounts.Language = propString(props, "Language")
	m.accounts.Location = propString(props, "Location")
	m.accounts.Locked = propBool(props, "Locked")
	m.accounts.PasswordMode = propInt32(props, "PasswordMode")
	m.accounts.UID = m.currentUID
	return nil
}

func (m *Manager) getUserIconFile(username string) (string, error) {
	if m.systemConn == nil {
		return "", fmt.Errorf("accounts service not available")
	}
	accountsManager := m.systemConn.Object("org.freedesktop.Accounts", dbus.ObjectPath("/org/freedesktop/Accounts"))
	var userPath dbus.ObjectPath
	if err := accountsManager.Call("org.freedesktop.Accounts.FindUserByName", 0, username).Store(&userPath); err != nil {
		return "", fmt.Errorf("user not found: %w", err)
	}
	userObj := m.systemConn.Object("org.freedesktop.Accounts", userPath)
	variant, err := userObj.GetProperty("org.freedesktop.Accounts.User.IconFile")
	if err != nil {
		return "", err
	}
	var icon string
	if err := variant.Store(&icon); err != nil {
		return "", err
	}
	return icon, nil
}

func (m *Manager) initializeSettings() error {
	if m.conn == nil {
		m.mu.Lock()
		m.settings.Available = false
		m.mu.Unlock()
		return fmt.Errorf("session bus unavailable")
	}
	m.settingsObj = m.conn.Object("org.freedesktop.portal.Desktop", dbus.ObjectPath("/org/freedesktop/portal/desktop"))
	if err := m.updateSettingsState(); err != nil {
		return err
	}
	if err := m.watchSettingsChanges(); err != nil {
		m.log.Warn("portal settings watcher unavailable", "err", err)
	}
	return nil
}

func (m *Manager) updateSettingsState() error {
	if m.settingsObj == nil {
		return fmt.Errorf("settings portal not available")
	}
	var variant dbus.Variant
	if err := m.settingsObj.Call("org.freedesktop.portal.Settings.ReadOne", 0, "org.freedesktop.appearance", "color-scheme").Store(&variant); err != nil {
		m.mu.Lock()
		m.settings.Available = false
		m.mu.Unlock()
		return err
	}
	colorScheme, err := variantUint32(variant)
	if err != nil {
		return err
	}
	m.mu.Lock()
	m.settings.Available = true
	m.settings.ColorScheme = colorScheme
	m.mu.Unlock()
	return nil
}

func (m *Manager) watchSettingsChanges() error {
	if m.conn == nil {
		return fmt.Errorf("session bus unavailable")
	}
	if err := m.conn.AddMatchSignal(
		dbus.WithMatchInterface("org.freedesktop.portal.Settings"),
		dbus.WithMatchMember("SettingChanged"),
	); err != nil {
		return err
	}
	signals := make(chan *dbus.Signal, 64)
	m.conn.Signal(signals)
	go func() {
		for sig := range signals {
			if sig.Name != "org.freedesktop.portal.Settings.SettingChanged" || len(sig.Body) < 3 {
				continue
			}
			namespace, _ := sig.Body[0].(string)
			key, _ := sig.Body[1].(string)
			if namespace != "org.freedesktop.appearance" || key != "color-scheme" {
				continue
			}
			variant, ok := sig.Body[2].(dbus.Variant)
			if !ok {
				continue
			}
			colorScheme, err := variantUint32(variant)
			if err != nil {
				continue
			}
			m.mu.Lock()
			changed := !m.settings.Available || m.settings.ColorScheme != colorScheme
			m.settings.Available = true
			m.settings.ColorScheme = colorScheme
			m.mu.Unlock()
			if changed {
				m.srv.Broadcast("freedesktop", m.GetState())
			}
		}
	}()
	return nil
}

func getAllProperties(obj dbus.BusObject, iface string) (map[string]dbus.Variant, error) {
	var props map[string]dbus.Variant
	if err := obj.Call("org.freedesktop.DBus.Properties.GetAll", 0, iface).Store(&props); err != nil {
		return nil, err
	}
	return props, nil
}

func propString(props map[string]dbus.Variant, key string) string {
	var value string
	if v, ok := props[key]; ok {
		_ = v.Store(&value)
	}
	return value
}

func propInt32(props map[string]dbus.Variant, key string) int32 {
	var value int32
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

func variantUint32(v dbus.Variant) (uint32, error) {
	var value uint32
	if err := v.Store(&value); err == nil {
		return value, nil
	}
	var i int32
	if err := v.Store(&i); err == nil {
		return uint32(i), nil
	}
	return 0, fmt.Errorf("unexpected color-scheme type: %s", v.Signature().String())
}

func validateIconPath(path string) error {
	if path == "" {
		return nil // AccountsService treats "" as "clear the icon"
	}
	if !filepath.IsAbs(path) {
		return fmt.Errorf("icon path must be absolute")
	}
	if strings.ContainsAny(path, "\x00\r\n") {
		return fmt.Errorf("invalid icon path")
	}
	// AccountsService copies the file as root into a world-readable location;
	// confine the source (post-symlink) to places avatar images live rather
	// than forwarding any root-readable path.
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return err
	}
	if !iconPathAllowed(resolved) {
		return fmt.Errorf("icon path must be inside your home directory or /usr/share")
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return fmt.Errorf("icon path is a directory")
	}
	if info.Size() > 10<<20 {
		return fmt.Errorf("profile image is too large")
	}
	return nil
}

func iconPathAllowed(resolved string) bool {
	roots := []string{"/usr/share"}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		if resolvedHome, err := filepath.EvalSymlinks(home); err == nil {
			roots = append(roots, resolvedHome)
		} else {
			roots = append(roots, home)
		}
	}
	for _, root := range roots {
		if resolved == root || strings.HasPrefix(resolved, strings.TrimSuffix(root, "/")+"/") {
			return true
		}
	}
	return false
}

func validateIconTheme(theme string) (string, error) {
	theme = strings.TrimSpace(theme)
	if theme == "" {
		return "", fmt.Errorf("icon theme required")
	}
	if len(theme) > 128 || strings.ContainsAny(theme, "/\\\x00\r\n") {
		return "", fmt.Errorf("invalid icon theme")
	}
	return theme, nil
}
