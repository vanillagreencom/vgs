package loginctl

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/godbus/dbus/v5"

	"vshell/backend/internal/server"
)

const (
	dbusDest             = "org.freedesktop.login1"
	dbusPath             = "/org/freedesktop/login1"
	dbusManagerInterface = "org.freedesktop.login1.Manager"
	dbusSessionInterface = "org.freedesktop.login1.Session"
	dbusUserInterface    = "org.freedesktop.login1.User"
	dbusPropsInterface   = "org.freedesktop.DBus.Properties"
)

type State struct {
	SessionID         string `json:"sessionId"`
	SessionPath       string `json:"sessionPath"`
	Locked            bool   `json:"locked"`
	Active            bool   `json:"active"`
	IdleHint          bool   `json:"idleHint"`
	IdleSinceHint     uint64 `json:"idleSinceHint"`
	LockedHint        bool   `json:"lockedHint"`
	SessionType       string `json:"sessionType"`
	SessionClass      string `json:"sessionClass"`
	User              uint32 `json:"user"`
	UserName          string `json:"userName"`
	RemoteHost        string `json:"remoteHost"`
	Service           string `json:"service"`
	TTY               string `json:"tty"`
	Display           string `json:"display"`
	Remote            bool   `json:"remote"`
	Seat              string `json:"seat"`
	VTNr              uint32 `json:"vtnr"`
	PreparingForSleep bool   `json:"preparingForSleep"`
}

type Manager struct {
	log *slog.Logger
	srv *server.Server

	conn      *dbus.Conn
	manager   dbus.BusObject
	session   dbus.BusObject
	sessionID string
	sessionOP dbus.ObjectPath

	mu    sync.RWMutex
	state State
	hooks []func(State)

	signals chan *dbus.Signal
	stop    chan struct{}

	inhibitMu             sync.Mutex
	inhibitFile           *os.File
	lockBeforeSuspend     atomic.Bool
	sleepInhibitorEnabled atomic.Bool
	inSleepCycle          atomic.Bool
	sleepCycleID          atomic.Uint64
	lockerReadyMu         sync.Mutex
	lockerReady           chan struct{}
	lockTimerMu           sync.Mutex
	lockTimer             *time.Timer
	fallbackDelay         time.Duration
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	if log == nil {
		log = slog.Default()
	}
	m, err := New(srv, log)
	if err != nil {
		return nil, err
	}

	srv.Register("loginctl", "loginctl.getState", m.handleGetState)
	srv.Register("loginctl", "loginctl.lock", m.handleLock)
	srv.Register("loginctl", "loginctl.unlock", m.handleUnlock)
	srv.Register("loginctl", "loginctl.setLockedHint", m.handleSetLockedHint)
	srv.Register("loginctl", "loginctl.setLockBeforeSuspend", m.handleSetLockBeforeSuspend)
	srv.Register("loginctl", "loginctl.setSleepInhibitorEnabled", m.handleSetSleepInhibitorEnabled)
	srv.Register("loginctl", "loginctl.lockerReady", m.handleLockerReady)
	srv.Register("loginctl", "loginctl.subscribe", m.handleGetState)
	srv.RegisterSnapshot("loginctl", func() any { return m.GetState() })
	return m, nil
}

func New(srv *server.Server, log *slog.Logger) (*Manager, error) {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return nil, fmt.Errorf("connect system bus: %w", err)
	}
	m := &Manager{
		log:                   log,
		srv:                   srv,
		conn:                  conn,
		manager:               conn.Object(dbusDest, dbus.ObjectPath(dbusPath)),
		signals:               make(chan *dbus.Signal, 64),
		stop:                  make(chan struct{}),
		sleepInhibitorEnabled: atomic.Bool{},
		fallbackDelay:         2 * time.Second,
	}
	m.sleepInhibitorEnabled.Store(false)

	if err := m.discoverSession(); err != nil {
		conn.Close()
		return nil, err
	}
	m.initializeFallbackDelay()
	if err := m.updateState(); err != nil {
		conn.Close()
		return nil, err
	}
	m.syncLockedFromHint()
	if err := m.addMatches(); err != nil {
		conn.Close()
		return nil, err
	}
	conn.Signal(m.signals)
	go m.signalLoop()
	return m, nil
}

func (m *Manager) Close() {
	close(m.stop)
	m.releaseSleepInhibitor()
	if m.conn != nil {
		m.conn.Close()
	}
}

func (m *Manager) discoverSession() error {
	if id := os.Getenv("XDG_SESSION_ID"); id != "" {
		if path, err := m.getSession(id); err == nil {
			if err := m.validateUserSession(path); err == nil {
				m.bindSession(id, path)
				return nil
			}
		}
	}
	if id, path, err := m.getSessionByPID(uint32(os.Getpid())); err == nil {
		m.bindSession(id, path)
		return nil
	}
	if id, path, err := m.getUserDisplaySession(); err == nil {
		m.bindSession(id, path)
		return nil
	}
	if id, path, err := m.findBestSession(); err == nil {
		m.bindSession(id, path)
		return nil
	}
	path, err := m.getSession("self")
	if err != nil {
		return fmt.Errorf("discover login session: %w", err)
	}
	m.bindSession("self", path)
	return nil
}

func (m *Manager) bindSession(id string, path dbus.ObjectPath) {
	m.sessionID = id
	m.sessionOP = path
	m.session = m.conn.Object(dbusDest, path)
	m.mu.Lock()
	m.state.SessionID = id
	m.state.SessionPath = string(path)
	m.mu.Unlock()
}

func (m *Manager) getSession(id string) (dbus.ObjectPath, error) {
	var out dbus.ObjectPath
	err := m.manager.Call(dbusManagerInterface+".GetSession", 0, id).Store(&out)
	return out, err
}

func (m *Manager) getSessionByPID(pid uint32) (string, dbus.ObjectPath, error) {
	var path dbus.ObjectPath
	if err := m.manager.Call(dbusManagerInterface+".GetSessionByPID", 0, pid).Store(&path); err != nil {
		return "", "", err
	}
	if err := m.validateUserSession(path); err != nil {
		return "", "", err
	}
	obj := m.conn.Object(dbusDest, path)
	var id dbus.Variant
	if err := obj.Call(dbusPropsInterface+".Get", 0, dbusSessionInterface, "Id").Store(&id); err != nil {
		return "", "", err
	}
	s, _ := id.Value().(string)
	if s == "" {
		return "", "", fmt.Errorf("empty session id")
	}
	return s, path, nil
}

func (m *Manager) getUserDisplaySession() (string, dbus.ObjectPath, error) {
	var userPath dbus.ObjectPath
	if err := m.manager.Call(dbusManagerInterface+".GetUser", 0, uint32(os.Getuid())).Store(&userPath); err != nil {
		return "", "", err
	}
	var display dbus.Variant
	if err := m.conn.Object(dbusDest, userPath).Call(dbusPropsInterface+".Get", 0, dbusUserInterface, "Display").Store(&display); err != nil {
		return "", "", err
	}
	pair, ok := display.Value().([]any)
	if !ok || len(pair) < 2 {
		return "", "", fmt.Errorf("unexpected Display property")
	}
	id, _ := pair[0].(string)
	path, _ := pair[1].(dbus.ObjectPath)
	if id == "" || path == "" {
		return "", "", fmt.Errorf("empty display session")
	}
	if err := m.validateUserSession(path); err != nil {
		return "", "", err
	}
	return id, path, nil
}

func (m *Manager) findBestSession() (string, dbus.ObjectPath, error) {
	var raw [][]any
	if err := m.manager.Call(dbusManagerInterface+".ListSessions", 0).Store(&raw); err != nil {
		return "", "", err
	}
	uid := uint32(os.Getuid())
	bestScore := -1
	var bestID string
	var bestPath dbus.ObjectPath
	for _, entry := range raw {
		if len(entry) < 5 {
			continue
		}
		entryUID, _ := entry[1].(uint32)
		if entryUID != uid {
			continue
		}
		id, _ := entry[0].(string)
		path, _ := entry[4].(dbus.ObjectPath)
		if id == "" || path == "" {
			continue
		}
		score := m.scoreSession(path)
		if score > bestScore {
			bestScore, bestID, bestPath = score, id, path
		}
	}
	if bestScore < 0 {
		return "", "", fmt.Errorf("no viable session for uid %d", uid)
	}
	return bestID, bestPath, nil
}

func (m *Manager) scoreSession(path dbus.ObjectPath) int {
	var props map[string]dbus.Variant
	if err := m.conn.Object(dbusDest, path).Call(dbusPropsInterface+".GetAll", 0, dbusSessionInterface).Store(&props); err != nil {
		return -1
	}
	if getString(props, "Class") != "user" || getBool(props, "Remote") {
		return -1
	}
	score := 0
	if getBool(props, "Active") {
		score += 100
	}
	switch getString(props, "Type") {
	case "wayland", "x11":
		score += 80
	case "tty":
		score += 10
	}
	if getSeat(props) != "" {
		score += 40
		if getSeat(props) == "seat0" {
			score += 10
		}
	}
	if getUint32(props, "VTNr") > 0 {
		score += 20
	}
	return score
}

func (m *Manager) validateUserSession(path dbus.ObjectPath) error {
	var props map[string]dbus.Variant
	if err := m.conn.Object(dbusDest, path).Call(dbusPropsInterface+".GetAll", 0, dbusSessionInterface).Store(&props); err != nil {
		return err
	}
	if class := getString(props, "Class"); class != "user" {
		return fmt.Errorf("session %s class is %q, not user", path, class)
	}
	if getBool(props, "Remote") {
		return fmt.Errorf("session %s is remote", path)
	}
	return nil
}

func (m *Manager) addMatches() error {
	matches := []string{
		fmt.Sprintf("type='signal',interface='%s',path='%s'", dbusSessionInterface, m.sessionOP),
		fmt.Sprintf("type='signal',sender='%s',interface='%s',member='PropertiesChanged',path='%s'", dbusDest, dbusPropsInterface, m.sessionOP),
		fmt.Sprintf("type='signal',interface='%s',member='PrepareForSleep',path='%s'", dbusManagerInterface, dbusPath),
		fmt.Sprintf("type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='%s'", dbusDest),
	}
	for _, match := range matches {
		if err := m.conn.BusObject().Call("org.freedesktop.DBus.AddMatch", 0, match).Err; err != nil {
			return fmt.Errorf("add match %s: %w", match, err)
		}
	}
	return nil
}

func (m *Manager) updateState() error {
	var props map[string]dbus.Variant
	if err := m.session.CallWithContext(context.Background(), dbusPropsInterface+".GetAll", 0, dbusSessionInterface).Store(&props); err != nil {
		return err
	}
	preparingForSleep, preparingErr := m.readPreparingForSleep()
	m.mu.Lock()
	m.state.Active = getBool(props, "Active")
	m.state.IdleHint = getBool(props, "IdleHint")
	m.state.IdleSinceHint = getUint64(props, "IdleSinceHint")
	m.state.LockedHint = getBool(props, "LockedHint")
	m.state.SessionType = getString(props, "Type")
	m.state.SessionClass = getString(props, "Class")
	m.state.User = getUserID(props)
	m.state.UserName = getString(props, "Name")
	m.state.RemoteHost = getString(props, "RemoteHost")
	m.state.Service = getString(props, "Service")
	m.state.TTY = getString(props, "TTY")
	m.state.Display = getString(props, "Display")
	m.state.Remote = getBool(props, "Remote")
	m.state.Seat = getSeat(props)
	m.state.VTNr = getUint32(props, "VTNr")
	if preparingErr == nil {
		m.state.PreparingForSleep = preparingForSleep
	}
	m.mu.Unlock()
	if preparingErr == nil && !preparingForSleep && m.inSleepCycle.Load() {
		m.finishSleepCycle()
	}
	return nil
}

func (m *Manager) GetState() State {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.state
}

func (m *Manager) syncLockedFromHint() {
	m.mu.Lock()
	m.state.Locked = m.state.LockedHint
	m.mu.Unlock()
}

func (m *Manager) AddStateListener(hook func(State)) {
	if hook == nil {
		return
	}
	m.mu.Lock()
	m.hooks = append(m.hooks, hook)
	state := m.state
	m.mu.Unlock()
	hook(state)
}

func (m *Manager) broadcastState() {
	state := m.GetState()
	m.srv.Broadcast("loginctl", state)
	m.mu.RLock()
	hooks := append([]func(State){}, m.hooks...)
	m.mu.RUnlock()
	for _, hook := range hooks {
		hook(state)
	}
}

func (m *Manager) readPreparingForSleep() (bool, error) {
	var variant dbus.Variant
	if err := m.manager.Call(dbusPropsInterface+".Get", 0, dbusManagerInterface, "PreparingForSleep").Store(&variant); err != nil {
		return false, err
	}
	preparing, _ := variant.Value().(bool)
	return preparing, nil
}

func (m *Manager) finishSleepCycle() {
	m.inSleepCycle.Store(false)
	m.signalLockerReady()
	m.stopLockTimer()
	if err := m.acquireSleepInhibitor(); err != nil {
		m.log.Warn("sleep inhibitor reacquire failed", "err", err)
	}
}

func (m *Manager) signalLoop() {
	for {
		select {
		case <-m.stop:
			return
		case sig := <-m.signals:
			if sig != nil {
				m.handleSignal(sig)
			}
		}
	}
}

func (m *Manager) handleSignal(sig *dbus.Signal) {
	switch sig.Name {
	case dbusSessionInterface + ".Lock":
		m.setLocked(true)
		if err := m.updateState(); err != nil {
			m.log.Warn("loginctl lock state refresh failed", "err", err)
		}
		m.broadcastState()
		if m.sleepInhibitorEnabled.Load() && m.inSleepCycle.Load() {
			id := m.sleepCycleID.Load()
			m.lockTimerMu.Lock()
			if m.lockTimer != nil {
				m.lockTimer.Stop()
			}
			m.lockTimer = time.AfterFunc(m.fallbackDelay, func() { m.releaseForCycle(id) })
			m.lockTimerMu.Unlock()
		}
	case dbusSessionInterface + ".Unlock":
		m.setLocked(false)
		if err := m.updateState(); err != nil {
			m.log.Warn("loginctl unlock state refresh failed", "err", err)
		}
		m.broadcastState()
		m.stopLockTimer()
		_ = m.acquireSleepInhibitor()
	case dbusManagerInterface + ".PrepareForSleep":
		if len(sig.Body) == 0 {
			return
		}
		preparing, _ := sig.Body[0].(bool)
		m.handlePrepareForSleep(preparing)
	case dbusPropsInterface + ".PropertiesChanged":
		m.handlePropertiesChanged(sig)
	case "org.freedesktop.DBus.NameOwnerChanged":
		if len(sig.Body) == 3 {
			name, _ := sig.Body[0].(string)
			newOwner, _ := sig.Body[2].(string)
			// A logind restart releases and then reacquires the bus name. Reinitialize on
			// acquisition rather than requiring both owners in the same signal.
			if name == dbusDest && newOwner != "" {
				if err := m.updateState(); err != nil {
					m.log.Warn("loginctl state refresh failed", "err", err)
				}
				m.syncLockedFromHint()
				if !m.inSleepCycle.Load() {
					// The old inhibitor fd is held against the dead logind;
					// drop it so a fresh one is taken from the new instance.
					m.releaseSleepInhibitor()
					_ = m.acquireSleepInhibitor()
				}
				m.broadcastState()
			}
		}
	}
}

func (m *Manager) setLocked(locked bool) {
	m.mu.Lock()
	m.state.Locked = locked
	m.mu.Unlock()
}

func (m *Manager) handlePrepareForSleep(preparing bool) {
	if preparing {
		cycleID := m.sleepCycleID.Add(1)
		m.inSleepCycle.Store(true)
		if m.lockBeforeSuspend.Load() {
			if err := m.Lock(); err != nil {
				m.log.Warn("lock-before-suspend failed", "err", err)
			}
		}
		readyCh := m.newLockerReadyCh()
		go func(id uint64, ch <-chan struct{}) {
			<-ch
			m.releaseForCycle(id)
		}(cycleID, readyCh)
	} else {
		m.finishSleepCycle()
		if err := m.updateState(); err != nil {
			m.log.Warn("resume state refresh failed", "err", err)
		}
	}

	m.mu.Lock()
	m.state.PreparingForSleep = preparing
	m.mu.Unlock()
	m.broadcastState()
}

func (m *Manager) handlePropertiesChanged(sig *dbus.Signal) {
	if len(sig.Body) < 2 {
		return
	}
	iface, _ := sig.Body[0].(string)
	if iface != dbusSessionInterface {
		return
	}
	changes, ok := sig.Body[1].(map[string]dbus.Variant)
	if !ok {
		return
	}
	if len(sig.Body) > 2 {
		if invalidated, ok := sig.Body[2].([]string); ok && len(invalidated) > 0 {
			if err := m.updateState(); err != nil {
				m.log.Warn("loginctl invalidated-property refresh failed", "err", err)
				return
			}
			m.broadcastState()
			return
		}
	}
	changed := false
	m.mu.Lock()
	for key, variant := range changes {
		switch key {
		case "Active":
			if v, ok := variant.Value().(bool); ok {
				m.state.Active = v
				changed = true
			}
		case "IdleHint":
			if v, ok := variant.Value().(bool); ok {
				m.state.IdleHint = v
				changed = true
			}
		case "IdleSinceHint":
			if v, ok := variant.Value().(uint64); ok {
				m.state.IdleSinceHint = v
				changed = true
			}
		case "LockedHint":
			if v, ok := variant.Value().(bool); ok {
				m.state.LockedHint = v
				m.state.Locked = v
				changed = true
			}
		}
	}
	m.mu.Unlock()
	if changed {
		m.broadcastState()
	}
}

func (m *Manager) Lock() error {
	if m.session == nil {
		return fmt.Errorf("session object unavailable")
	}
	if err := m.session.Call(dbusSessionInterface+".Lock", 0).Err; err != nil {
		return fmt.Errorf("lock session: %w", err)
	}
	return nil
}

func (m *Manager) Unlock() error {
	if m.session == nil {
		return fmt.Errorf("session object unavailable")
	}
	if err := m.session.Call(dbusSessionInterface+".Unlock", 0).Err; err != nil {
		return fmt.Errorf("unlock session: %w", err)
	}
	return nil
}

func (m *Manager) SetLockedHint(locked bool) error {
	if m.session == nil {
		return fmt.Errorf("session object unavailable")
	}
	if err := m.session.Call(dbusSessionInterface+".SetLockedHint", 0, locked).Err; err != nil {
		return fmt.Errorf("set locked hint: %w", err)
	}
	return nil
}

func (m *Manager) SetLockBeforeSuspend(enabled bool) {
	m.lockBeforeSuspend.Store(enabled)
}

func (m *Manager) SetSleepInhibitorEnabled(enabled bool) error {
	m.sleepInhibitorEnabled.Store(enabled)
	if enabled {
		return m.acquireSleepInhibitor()
	}
	m.releaseSleepInhibitor()
	return nil
}

func (m *Manager) acquireSleepInhibitor() error {
	if !m.sleepInhibitorEnabled.Load() {
		return nil
	}
	m.inhibitMu.Lock()
	defer m.inhibitMu.Unlock()
	if m.inhibitFile != nil {
		return nil
	}
	var fd dbus.UnixFD
	if err := m.manager.Call(dbusManagerInterface+".Inhibit", 0, "sleep", "VanillaGreen Shell", "Lock before suspend", "delay").Store(&fd); err != nil {
		return err
	}
	m.inhibitFile = os.NewFile(uintptr(fd), "vshell-loginctl-sleep-inhibit")
	return nil
}

func (m *Manager) releaseSleepInhibitor() {
	m.inhibitMu.Lock()
	f := m.inhibitFile
	m.inhibitFile = nil
	m.inhibitMu.Unlock()
	if f != nil {
		_ = f.Close()
	}
}

func (m *Manager) releaseForCycle(id uint64) {
	// Check and release under the same lock: a fallback timer firing during
	// resume could otherwise pass these checks, lose the race with
	// finishSleepCycle's reacquire, and then close the fresh inhibitor fd,
	// leaving the next suspend with no delay inhibitor.
	m.inhibitMu.Lock()
	defer m.inhibitMu.Unlock()
	if !m.inSleepCycle.Load() || m.sleepCycleID.Load() != id {
		return
	}
	f := m.inhibitFile
	m.inhibitFile = nil
	if f != nil {
		_ = f.Close()
	}
}

func (m *Manager) initializeFallbackDelay() {
	var variant dbus.Variant
	if err := m.manager.Call(dbusPropsInterface+".Get", 0, dbusManagerInterface, "InhibitDelayMaxUSec").Store(&variant); err != nil {
		m.fallbackDelay = 2 * time.Second
		return
	}
	if usec, ok := variant.Value().(uint64); ok {
		delay := time.Duration(usec) * time.Microsecond * 8 / 10
		if delay < 2*time.Second {
			delay = 2 * time.Second
		}
		if delay > 4*time.Second {
			delay = 4 * time.Second
		}
		m.fallbackDelay = delay
	}
}

func (m *Manager) newLockerReadyCh() chan struct{} {
	m.lockerReadyMu.Lock()
	defer m.lockerReadyMu.Unlock()
	// Release a waiter from a cycle that never resolved (duplicated
	// PrepareForSleep(true)); its stale cycle ID makes the release a no-op.
	if m.lockerReady != nil {
		close(m.lockerReady)
	}
	m.lockerReady = make(chan struct{})
	return m.lockerReady
}

func (m *Manager) signalLockerReady() {
	m.lockerReadyMu.Lock()
	ch := m.lockerReady
	if ch != nil {
		close(ch)
		m.lockerReady = nil
	}
	m.lockerReadyMu.Unlock()
}

func (m *Manager) stopLockTimer() {
	m.lockTimerMu.Lock()
	if m.lockTimer != nil {
		m.lockTimer.Stop()
		m.lockTimer = nil
	}
	m.lockTimerMu.Unlock()
}

type boolParams struct {
	Enabled bool `json:"enabled"`
	Locked  bool `json:"locked"`
}

func (m *Manager) handleGetState(json.RawMessage) (any, error) {
	if err := m.updateState(); err != nil {
		return nil, err
	}
	return m.GetState(), nil
}

func (m *Manager) handleLock(json.RawMessage) (any, error) {
	if err := m.Lock(); err != nil {
		return nil, err
	}
	return map[string]any{"success": true, "message": "locked"}, nil
}

func (m *Manager) handleUnlock(json.RawMessage) (any, error) {
	if err := m.Unlock(); err != nil {
		return nil, err
	}
	return map[string]any{"success": true, "message": "unlocked"}, nil
}

func (m *Manager) handleSetLockedHint(params json.RawMessage) (any, error) {
	var p boolParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.SetLockedHint(p.Locked); err != nil {
		return nil, err
	}
	return map[string]any{"success": true}, nil
}

func (m *Manager) handleSetLockBeforeSuspend(params json.RawMessage) (any, error) {
	var p boolParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	m.SetLockBeforeSuspend(p.Enabled)
	return map[string]any{"success": true}, nil
}

func (m *Manager) handleSetSleepInhibitorEnabled(params json.RawMessage) (any, error) {
	var p boolParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.SetSleepInhibitorEnabled(p.Enabled); err != nil {
		return nil, err
	}
	return map[string]any{"success": true}, nil
}

func (m *Manager) handleLockerReady(json.RawMessage) (any, error) {
	m.stopLockTimer()
	m.releaseForCycle(m.sleepCycleID.Load())
	if m.inSleepCycle.Load() {
		m.signalLockerReady()
	}
	return map[string]any{"success": true, "message": "ok"}, nil
}

func getString(props map[string]dbus.Variant, key string) string {
	if v, ok := props[key]; ok {
		if s, ok := v.Value().(string); ok {
			return s
		}
	}
	return ""
}

func getBool(props map[string]dbus.Variant, key string) bool {
	if v, ok := props[key]; ok {
		if b, ok := v.Value().(bool); ok {
			return b
		}
	}
	return false
}

func getUint32(props map[string]dbus.Variant, key string) uint32 {
	if v, ok := props[key]; ok {
		if u, ok := v.Value().(uint32); ok {
			return u
		}
	}
	return 0
}

func getUint64(props map[string]dbus.Variant, key string) uint64 {
	if v, ok := props[key]; ok {
		if u, ok := v.Value().(uint64); ok {
			return u
		}
	}
	return 0
}

func getUserID(props map[string]dbus.Variant) uint32 {
	if v, ok := props["User"]; ok {
		if pair, ok := v.Value().([]any); ok && len(pair) > 0 {
			if uid, ok := pair[0].(uint32); ok {
				return uid
			}
		}
	}
	return 0
}

func getSeat(props map[string]dbus.Variant) string {
	if v, ok := props["Seat"]; ok {
		if pair, ok := v.Value().([]any); ok && len(pair) > 0 {
			if seat, ok := pair[0].(string); ok {
				return seat
			}
		}
	}
	return ""
}
