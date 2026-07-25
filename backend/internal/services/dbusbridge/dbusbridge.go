package dbusbridge

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/godbus/dbus/v5"

	"vshell/backend/internal/server"
)

const (
	login1Dest    = "org.freedesktop.login1"
	login1Path    = "/org/freedesktop/login1"
	login1Iface   = "org.freedesktop.login1.Manager"
	prepareMember = "PrepareForSleep"
)

type Manager struct {
	log *slog.Logger
	srv *server.Server

	conn    *dbus.Conn
	signals chan *dbus.Signal
	stop    chan struct{}

	mu   sync.RWMutex
	subs map[string]subscription
}

type subscription struct {
	Bus       string `json:"bus"`
	Sender    string `json:"sender"`
	Path      string `json:"path"`
	Interface string `json:"interface"`
	Member    string `json:"member"`
}

type signalEvent struct {
	SubscriptionID string `json:"subscriptionId"`
	Sender         string `json:"sender"`
	Path           string `json:"path"`
	Interface      string `json:"interface"`
	Member         string `json:"member"`
	Body           []any  `json:"body"`
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
		log:     log,
		srv:     srv,
		conn:    conn,
		signals: make(chan *dbus.Signal, 64),
		stop:    make(chan struct{}),
		subs:    map[string]subscription{},
	}
	srv.Register("dbus", "dbus.subscribe", m.handleSubscribe)
	srv.Register("dbus", "dbus.unsubscribe", m.handleUnsubscribe)
	conn.Signal(m.signals)
	go m.signalLoop()
	return m, nil
}

func (m *Manager) Close() {
	close(m.stop)
	if m.conn != nil {
		m.conn.Close()
	}
}

type subscribeParams struct {
	Bus       string `json:"bus"`
	Sender    string `json:"sender"`
	Path      string `json:"path"`
	Interface string `json:"interface"`
	Member    string `json:"member"`
}

type unsubscribeParams struct {
	SubscriptionID string `json:"subscriptionId"`
}

func (m *Manager) handleSubscribe(params json.RawMessage) (any, error) {
	var p subscribeParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := validatePrepareForSleep(p); err != nil {
		return nil, err
	}
	id := randomID()
	// The match rule is identical for every subscriber; only install it on the
	// bus for the first one so the single RemoveMatch on the last unsubscribe
	// leaves no leaked rules behind.
	if !m.hasPrepareSubscribers() {
		match := prepareForSleepMatch()
		if err := m.conn.BusObject().Call("org.freedesktop.DBus.AddMatch", 0, match).Err; err != nil {
			return nil, fmt.Errorf("add PrepareForSleep match: %w", err)
		}
	}
	m.mu.Lock()
	m.subs[id] = subscription{
		Bus:       "system",
		Sender:    login1Dest,
		Path:      login1Path,
		Interface: login1Iface,
		Member:    prepareMember,
	}
	m.mu.Unlock()
	return map[string]string{"subscriptionId": id}, nil
}

func (m *Manager) handleUnsubscribe(params json.RawMessage) (any, error) {
	var p unsubscribeParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.SubscriptionID == "" {
		return nil, fmt.Errorf("subscriptionId required")
	}
	m.mu.Lock()
	_, ok := m.subs[p.SubscriptionID]
	delete(m.subs, p.SubscriptionID)
	m.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("subscription not found: %s", p.SubscriptionID)
	}
	if !m.hasPrepareSubscribers() {
		_ = m.conn.BusObject().Call("org.freedesktop.DBus.RemoveMatch", 0, prepareForSleepMatch()).Err
	}
	return map[string]bool{"success": true}, nil
}

func validatePrepareForSleep(p subscribeParams) error {
	if p.Bus != "system" {
		return fmt.Errorf("dbus.subscribe is restricted to system PrepareForSleep in Phase 2")
	}
	if p.Sender != "" && p.Sender != login1Dest {
		return fmt.Errorf("unsupported sender: %s", p.Sender)
	}
	if p.Path != "" && p.Path != login1Path {
		return fmt.Errorf("unsupported path: %s", p.Path)
	}
	if p.Interface != "" && p.Interface != login1Iface {
		return fmt.Errorf("unsupported interface: %s", p.Interface)
	}
	if p.Member != "" && p.Member != prepareMember {
		return fmt.Errorf("unsupported member: %s", p.Member)
	}
	return nil
}

func prepareForSleepMatch() string {
	return strings.Join([]string{
		"type='signal'",
		"path='" + login1Path + "'",
		"interface='" + login1Iface + "'",
		"member='" + prepareMember + "'",
	}, ",")
}

func (m *Manager) hasPrepareSubscribers() bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.subs) > 0
}

func (m *Manager) signalLoop() {
	for {
		select {
		case <-m.stop:
			return
		case sig := <-m.signals:
			if sig == nil || sig.Name != login1Iface+"."+prepareMember || string(sig.Path) != login1Path {
				continue
			}
			m.broadcast(sig)
		}
	}
}

func (m *Manager) broadcast(sig *dbus.Signal) {
	body := make([]any, 0, len(sig.Body))
	for _, v := range sig.Body {
		body = append(body, normalize(v))
	}
	m.mu.RLock()
	ids := make([]string, 0, len(m.subs))
	for id := range m.subs {
		ids = append(ids, id)
	}
	m.mu.RUnlock()
	for _, id := range ids {
		m.srv.Broadcast("dbus", signalEvent{
			SubscriptionID: id,
			Sender:         sig.Sender,
			Path:           string(sig.Path),
			Interface:      login1Iface,
			Member:         prepareMember,
			Body:           body,
		})
	}
}

func normalize(v any) any {
	switch x := v.(type) {
	case dbus.Variant:
		return normalize(x.Value())
	case dbus.ObjectPath:
		return string(x)
	case []any:
		out := make([]any, 0, len(x))
		for _, item := range x {
			out = append(out, normalize(item))
		}
		return out
	case map[string]dbus.Variant:
		out := map[string]any{}
		for k, item := range x {
			out[k] = normalize(item)
		}
		return out
	default:
		return v
	}
}

func randomID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		// Unique fallback: a constant here would silently overwrite an
		// existing subscription in the subs map.
		return fmt.Sprintf("dbus-fallback-%d", fallbackID.Add(1))
	}
	return "dbus-" + hex.EncodeToString(b[:])
}

var fallbackID atomic.Uint64
