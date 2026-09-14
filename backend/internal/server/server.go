// Package server implements the VGS backend Unix-socket daemon: line-delimited
// JSON request/response plus a subscription broadcaster. It is transport and
// dispatch only; system-integration services register their methods onto it.
package server

import (
	"bufio"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"sort"
	"sync"
	"syscall"
	"time"

	"vshell/backend/internal/protocol"
	"vshell/backend/internal/registry"
)

// maxLine limits the memory accepted for one JSON message.
const maxLine = 16 << 20 // 16 MiB

// methodDepth bounds the calls one method may hold waiting for its worker.
const methodDepth = 64

// HandlerFunc handles one method call. It receives raw params and returns a
// JSON-serializable result or an error surfaced to the client.
type HandlerFunc func(params json.RawMessage) (any, error)

// LatestKeyFunc derives a keep-latest method's coalescing key from a call's raw
// params. Two calls sharing a key address the same thing, so the newer subsumes
// the older; two calls with different keys never replace one another.
type LatestKeyFunc func(params json.RawMessage) string

// methodEntry is one registered method. latestKey is nil for an ordinary
// method, so a single lookup answers both what to run and how to queue it.
type methodEntry struct {
	handle    HandlerFunc
	latestKey LatestKeyFunc
}

// subscription is one connection's requested service set. An empty set and the
// "all" wildcard both cover every service.
type subscription map[string]bool

func (sub subscription) covers(service string) bool {
	return len(sub) == 0 || sub["all"] || sub[service]
}

// snapshotSource is a service's subscribe-time state. read returns
// last-known-good state without blocking. refresh, when set, asks the service's
// own goroutine to re-run the live query behind that state; the result reaches
// subscribers through Broadcast.
type snapshotSource struct {
	read    func() any
	refresh func()
}

// Server is a running daemon. The zero value is not usable; use New.
type Server struct {
	log *slog.Logger
	uid uint32

	mu           sync.RWMutex
	handlers     map[string]*methodEntry
	capabilities map[string]bool
	snapshots    map[string]*snapshotSource
	// coalesced holds the services whose every broadcast carries the whole of
	// that service's state, so an unread frame may be replaced by a newer one.
	coalesced   map[string]bool
	subscribers map[*conn]subscription

	workersMu sync.Mutex
	workers   map[string]*worker
}

// New creates a Server that only accepts peers whose credentials match uid.
// The core methods (ping, getServerInfo, subscribe) are always available; the
// "core" capability is always advertised.
func New(uid uint32, log *slog.Logger) *Server {
	if log == nil {
		log = slog.Default()
	}
	s := &Server{
		log:          log,
		uid:          uid,
		handlers:     map[string]*methodEntry{},
		capabilities: map[string]bool{"core": true},
		snapshots:    map[string]*snapshotSource{},
		coalesced:    map[string]bool{},
		subscribers:  map[*conn]subscription{},
		workers:      map[string]*worker{},
	}
	s.handlers["ping"] = &methodEntry{handle: func(json.RawMessage) (any, error) {
		return map[string]bool{"pong": true}, nil
	}}
	s.handlers["getServerInfo"] = &methodEntry{handle: func(json.RawMessage) (any, error) {
		return s.info(), nil
	}}
	// "subscribe" is dispatched specially (it needs the connection); registering
	// a handler-less placeholder keeps it visible in the advertised method list.
	s.handlers["subscribe"] = &methodEntry{}
	return s
}

// Register adds a method handler and its capability. Safe to call before Serve.
func (s *Server) Register(capability, method string, h HandlerFunc) {
	s.mu.Lock()
	defer s.mu.Unlock()
	_ = s.registerLocked(capability, method, h)
}

// RegisterLatest adds a method whose calls are idempotent within a coalescing
// key. While one call runs, a waiting call is replaced by a newer call with the
// same key instead of queueing behind it, so dragging a slider applies the
// value the user released on rather than replaying every value it passed
// through. Calls with different keys never replace one another: key must
// separate calls that address different things, such as one backlight from
// another, or one display's write is lost to another display's.
//
// The slot is per key and per method, and it is shared by every connection, not
// held per connection. A replaced call is answered with a superseded result,
// never dropped in silence and never reported as a failure.
func (s *Server) RegisterLatest(capability, method string, h HandlerFunc, key LatestKeyFunc) {
	if key == nil {
		// Without a key every call for this method would share one slot, which
		// silently drops writes addressed elsewhere.
		panic("RegisterLatest(" + method + "): a keep-latest method needs a coalescing key")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.registerLocked(capability, method, h).latestKey = key
}

// WholeStateKey is the coalescing key for a setter that writes one shared
// thing, where the newest call subsumes every earlier one outright.
func WholeStateKey(json.RawMessage) string { return "whole-state" }

func (s *Server) registerLocked(capability, method string, h HandlerFunc) *methodEntry {
	if capability != "" {
		s.capabilities[capability] = true
	}
	entry := &methodEntry{handle: h}
	s.handlers[method] = entry
	return entry
}

// CoalesceBroadcasts declares that every broadcast under service carries the
// whole of that service's state, so a frame a slow reader has not taken yet may
// be replaced by a newer one. Declare it only when that holds: a service that
// broadcasts distinct events under one name — a per-device pairing prompt, a
// per-URL open request, a per-subscription D-Bus signal — loses the earlier
// event outright, with nothing to report it. A state carrying an edge the shell
// acts on, such as a lock or a suspend flag, is not whole state either: the
// edge is gone once a later frame overwrites it.
//
// The declared set has an owner: backend/internal/services/coalescing_test.go
// carries one row per declared service, so a new declaration is a deliberate
// edit there as well as here.
func (s *Server) CoalesceBroadcasts(service string) {
	if service == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.coalesced[service] = true
}

// AddCapability advertises a capability that is event-only or whose methods are
// registered elsewhere.
func (s *Server) AddCapability(capability string) {
	if capability == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.capabilities[capability] = true
}

// RegisterSnapshot adds the state emitted immediately after subscribe. snapshot
// must return the service's last-known-good state without blocking: it runs on
// the subscribing connection's read goroutine, where a live query would hold
// every other service's snapshot behind it. A service whose state comes from an
// external command registers the query itself with RegisterSnapshotRefresh.
//
// A nil return means the service has no state yet, and sends no frame. An empty
// state would otherwise reach the shell as fact and blank a list that the
// refresh is about to fill.
func (s *Server) RegisterSnapshot(service string, snapshot func() any) {
	if service == "" || snapshot == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.snapshotLocked(service).read = snapshot
}

// RegisterSnapshotRefresh adds the kick that subscribe uses to ask a service to
// re-run its live query on its own goroutine. refresh must return without
// waiting for that query.
func (s *Server) RegisterSnapshotRefresh(service string, refresh func()) {
	if service == "" || refresh == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.snapshotLocked(service).refresh = refresh
}

func (s *Server) snapshotLocked(service string) *snapshotSource {
	src, ok := s.snapshots[service]
	if !ok {
		src = &snapshotSource{}
		s.snapshots[service] = src
	}
	return src
}

// Capabilities returns the advertised capability names, sorted.
func (s *Server) Capabilities() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return sortedKeys(s.capabilities)
}

// Methods returns the advertised method names, sorted.
func (s *Server) Methods() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return sortedKeys(s.handlers)
}

func (s *Server) info() registry.ServerInfo {
	return registry.Info(s.Capabilities(), s.Methods())
}

// Serve accepts connections until ln is closed. It returns the accept error
// unless it is a normal close.
func (s *Server) Serve(ln net.Listener) error {
	for {
		nc, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			// Transient accept errors should not kill the daemon, but a
			// persistent one (e.g. EMFILE) must not busy-loop either.
			s.log.Warn("accept failed", "err", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		uc, ok := nc.(*net.UnixConn)
		if !ok {
			nc.Close()
			continue
		}
		if !s.peerAllowed(uc) {
			s.log.Warn("rejected connection: peer uid mismatch")
			nc.Close()
			continue
		}
		go s.handleConn(newConn(uc, s.log))
	}
}

// peerAllowed enforces the same-UID trust boundary via SO_PEERCRED.
func (s *Server) peerAllowed(uc *net.UnixConn) bool {
	raw, err := uc.SyscallConn()
	if err != nil {
		return false
	}
	var ucred *syscall.Ucred
	var credErr error
	if ctlErr := raw.Control(func(fd uintptr) {
		ucred, credErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	}); ctlErr != nil || credErr != nil || ucred == nil {
		return false
	}
	return ucred.Uid == s.uid
}

func (s *Server) handleConn(c *conn) {
	defer func() {
		if r := recover(); r != nil {
			s.log.Error("connection panic", "err", r)
		}
		s.dropSubscriber(c)
		c.close()
	}()

	sc := bufio.NewScanner(c.uc)
	sc.Buffer(make([]byte, 0, 64<<10), maxLine)
	for sc.Scan() {
		if len(sc.Bytes()) == 0 {
			continue
		}
		// The worker outlives this Scan. Copy the input to give request fields
		// independent storage.
		line := append([]byte(nil), sc.Bytes()...)
		var req protocol.Request
		if err := json.Unmarshal(line, &req); err != nil {
			s.log.Warn("bad request json", "err", err)
			continue
		}
		s.dispatch(c, &req)
	}
	// Scan stops on EOF (nil) or error (e.g. bufio.ErrTooLong for a frame over
	// maxLine); surface the error so a dropped connection is not invisible.
	if err := sc.Err(); err != nil {
		s.log.Warn("connection read loop ended with error", "err", err)
	}
}

func (s *Server) dispatch(c *conn, req *protocol.Request) {
	if req.Method == "subscribe" {
		s.handleSubscribe(c, req)
		return
	}

	s.mu.RLock()
	entry, known := s.handlers[req.Method]
	s.mu.RUnlock()

	if !known || entry.handle == nil {
		c.send(protocol.Response{ID: req.ID, Error: "unknown method: " + req.Method})
		return
	}
	// Each method has a worker so a slow handler does not hold the read
	// goroutine, and calls to the same method stay in order.
	job := call{
		run: func() {
			defer func() {
				if r := recover(); r != nil {
					s.log.Error("handler panic", "method", req.Method, "err", r)
					c.send(protocol.Response{ID: req.ID, Error: "internal: handler panic"})
				}
			}()
			result, err := entry.handle(req.Params)
			if err != nil {
				c.send(protocol.Response{ID: req.ID, Error: err.Error()})
				return
			}
			c.send(protocol.Response{ID: req.ID, Result: result})
		},
		// A superseded call is answered as a success: a newer call for the same
		// key took over the caller's intent, which is not a failure and must not
		// be reported to the user as one.
		superseded: func() {
			c.send(protocol.Response{ID: req.ID, Result: map[string]bool{"superseded": true}})
		},
	}

	key := ""
	if entry.latestKey != nil {
		key = entry.latestKey(req.Params)
	}
	replaced, outcome := s.worker(req.Method).offer(key, job)
	switch outcome {
	case pushQueued, pushClosed:
	case pushReplaced:
		replaced.superseded()
	case pushFull:
		// Blocking here would stall every other method on this socket, including
		// the lock call that raises the lock screen.
		c.send(protocol.Response{ID: req.ID, Error: "busy: " + req.Method + " has too many calls queued"})
	}
}

// worker returns the method's worker, creating it on first use.
func (s *Server) worker(method string) *worker {
	s.workersMu.Lock()
	defer s.workersMu.Unlock()
	if w, ok := s.workers[method]; ok {
		return w
	}
	w := &worker{queue: newCoalescingQueue[call](methodDepth)}
	s.workers[method] = w
	go func() {
		for {
			j, ok := w.queue.pop()
			if !ok {
				return
			}
			s.runJob(method, j.run)
		}
	}()
	return w
}

// call is one queued method invocation. superseded answers the client when a
// keep-latest method replaces this call with a newer one under the same key.
type call struct {
	run        func()
	superseded func()
}

// worker serializes one method's calls on a single goroutine. An ordinary
// method passes an empty key, so every call queues; a keep-latest method passes
// its coalescing key, so the newest call under that key replaces the one
// waiting.
type worker struct {
	queue *coalescingQueue[call]
}

func (w *worker) offer(key string, c call) (call, pushOutcome) {
	return w.queue.push(key, c)
}

func (s *Server) runJob(method string, job func()) {
	defer func() {
		if r := recover(); r != nil {
			s.log.Error("handler panic", "method", method, "err", r)
		}
	}()
	job()
}

// subscribeParams ignores unknown service names so clients can request services
// that this backend does not provide.
type subscribeParams struct {
	Services []string `json:"services"`
}

func (s *Server) handleSubscribe(c *conn, req *protocol.Request) {
	var p subscribeParams
	if len(req.Params) > 0 {
		if err := json.Unmarshal(req.Params, &p); err != nil {
			// Absent params legitimately means "subscribe to all"; malformed
			// params must not silently fall into that catch-all, so log it.
			s.log.Warn("subscribe params malformed, treating as subscribe-all", "err", err)
		}
	}

	set := subscription{}
	for _, svc := range p.Services {
		set[svc] = true
	}

	s.mu.Lock()
	prev, resubscribed := s.subscribers[c]
	s.subscribers[c] = set
	type covered struct {
		source *snapshotSource
		// snapshot is false for a service the previous subscription already
		// covered: every popout open re-sends the whole set, and re-delivering a
		// snapshot re-runs the shell's per-service setup on each open. The
		// refresh still runs, so a service whose first query failed is retried
		// rather than left silent for the life of the connection.
		snapshot bool
	}
	services := make(map[string]covered, len(s.snapshots))
	for service, src := range s.snapshots {
		if !set.covers(service) {
			continue
		}
		services[service] = covered{
			source:   src,
			snapshot: !resubscribed || !prev.covers(service),
		}
	}
	s.mu.Unlock()

	c.send(protocol.Response{Result: protocol.Event{Service: "server", Data: s.info()}})
	for service, cov := range services {
		// One read per service per subscribe: the value decides both whether a
		// snapshot goes out and whether the service still needs a query.
		mark := c.mark()
		var state any
		if cov.source.read != nil {
			state = cov.source.read()
		}
		if cov.snapshot && state != nil {
			// Never coalesced, whatever the service declares: the cache only
			// moves forward, so this read is no older than any frame queued
			// before it began, and replacing such a frame in place would drop
			// it outright. A frame that arrives after the read began is newer
			// than the read, so the push is dropped instead; without that, a
			// lock raised during the read would be undone by this frame, which
			// for a service with no refresh nothing is scheduled to correct.
			c.sendEventUnlessOvertaken(service, state, false, mark)
		}
		if cov.source.refresh == nil {
			continue
		}
		// A service the subscription already covered with state in hand needs
		// no query: every popout open re-sends the whole set, and re-running
		// those queries is the cost this contract exists to remove. A service
		// with nothing recorded is retried on every subscribe until one
		// succeeds.
		if !cov.snapshot && state != nil {
			continue
		}
		cov.source.refresh()
	}
}

func (s *Server) dropSubscriber(c *conn) {
	s.mu.Lock()
	delete(s.subscribers, c)
	s.mu.Unlock()
}

// Broadcast pushes an event to every connection subscribed to service (or to
// "all"). It never waits on a peer: each connection owns a bounded queue and a
// writer goroutine, so a stalled subscriber cannot delay the caller's event
// loop. A frame coalesces with an unread one only for a service declared
// through CoalesceBroadcasts; every other service keeps each frame.
func (s *Server) Broadcast(service string, data any) {
	s.mu.RLock()
	coalesce := s.coalesced[service]
	targets := make([]*conn, 0, len(s.subscribers))
	for c, set := range s.subscribers {
		if set.covers(service) {
			targets = append(targets, c)
		}
	}
	s.mu.RUnlock()
	for _, c := range targets {
		c.sendEvent(service, data, coalesce)
	}
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
