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
	handlers     map[string]HandlerFunc
	keepLatest   map[string]bool
	capabilities map[string]bool
	snapshots    map[string]*snapshotSource
	subscribers  map[*conn]subscription

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
		handlers:     map[string]HandlerFunc{},
		keepLatest:   map[string]bool{},
		capabilities: map[string]bool{"core": true},
		snapshots:    map[string]*snapshotSource{},
		subscribers:  map[*conn]subscription{},
		workers:      map[string]*worker{},
	}
	s.handlers["ping"] = func(json.RawMessage) (any, error) {
		return map[string]bool{"pong": true}, nil
	}
	s.handlers["getServerInfo"] = func(json.RawMessage) (any, error) {
		return s.info(), nil
	}
	// "subscribe" is dispatched specially (it needs the connection); registering
	// a placeholder keeps it visible in the advertised method list.
	s.handlers["subscribe"] = nil
	return s
}

// Register adds a method handler and its capability. Safe to call before Serve.
func (s *Server) Register(capability, method string, h HandlerFunc) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.registerLocked(capability, method, h)
}

// RegisterLatest adds a method whose calls are idempotent, meaning the newest
// call subsumes every earlier one. While a call runs, a second waiting call is
// replaced by the newest instead of queueing behind it, so dragging a slider
// applies the value the user released on rather than replaying every value it
// passed through. A replaced call is answered with a superseded error, never
// dropped in silence.
func (s *Server) RegisterLatest(capability, method string, h HandlerFunc) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.registerLocked(capability, method, h)
	s.keepLatest[method] = true
}

func (s *Server) registerLocked(capability, method string, h HandlerFunc) {
	if capability != "" {
		s.capabilities[capability] = true
	}
	s.handlers[method] = h
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
	h, known := s.handlers[req.Method]
	keepLatest := s.keepLatest[req.Method]
	s.mu.RUnlock()

	if !known || h == nil {
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
			result, err := h(req.Params)
			if err != nil {
				c.send(protocol.Response{ID: req.ID, Error: err.Error()})
				return
			}
			c.send(protocol.Response{ID: req.ID, Result: result})
		},
		superseded: func() {
			c.send(protocol.Response{ID: req.ID, Error: "superseded: a newer " + req.Method + " call replaced this one"})
		},
	}

	w := s.worker(req.Method, keepLatest)
	if keepLatest {
		if replaced, ok := w.offerLatest(job); ok {
			replaced.superseded()
		}
		return
	}
	if !w.offer(job) {
		// Blocking here would stall every other method on this socket, including
		// the lock call that raises the lock screen.
		c.send(protocol.Response{ID: req.ID, Error: "busy: " + req.Method + " has too many calls queued"})
	}
}

// worker returns the method's FIFO worker, creating it on first use.
func (s *Server) worker(method string, keepLatest bool) *worker {
	s.workersMu.Lock()
	defer s.workersMu.Unlock()
	w, ok := s.workers[method]
	if ok {
		return w
	}
	depth := methodDepth
	if keepLatest {
		// One waiting call is all a keep-latest method ever holds: the next
		// arrival replaces it.
		depth = 1
	}
	w = &worker{jobs: make(chan call, depth)}
	s.workers[method] = w
	go func() {
		for j := range w.jobs {
			s.runJob(method, j.run)
		}
	}()
	return w
}

// call is one queued method invocation. superseded answers the client when a
// keep-latest method replaces this call with a newer one.
type call struct {
	run        func()
	superseded func()
}

// worker serializes one method's calls on a single goroutine.
type worker struct {
	jobs chan call

	// latestMu makes the take-then-replace in offerLatest atomic against other
	// callers, so the one-slot queue cannot overflow.
	latestMu sync.Mutex
}

// offer queues c and reports whether the method's queue had room.
func (w *worker) offer(c call) bool {
	select {
	case w.jobs <- c:
		return true
	default:
		return false
	}
}

// offerLatest queues c in place of any call still waiting, returning the
// replaced call so its client can be told it was superseded.
func (w *worker) offerLatest(c call) (call, bool) {
	w.latestMu.Lock()
	defer w.latestMu.Unlock()
	var replaced call
	found := false
	select {
	case replaced = <-w.jobs:
		found = true
	default:
	}
	w.jobs <- c
	return replaced, found
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
	added := make(map[string]*snapshotSource, len(s.snapshots))
	for service, src := range s.snapshots {
		if !set.covers(service) {
			continue
		}
		// A repeat subscribe re-sends only what this connection does not already
		// hold: every popout open re-sends the whole set, and re-delivering it
		// re-runs the shell's per-service setup on each open.
		if resubscribed && prev.covers(service) {
			continue
		}
		added[service] = src
	}
	s.mu.Unlock()

	c.send(protocol.Response{Result: protocol.Event{Service: "server", Data: s.info()}})
	for service, src := range added {
		if src.read == nil {
			continue
		}
		if data := src.read(); data != nil {
			c.sendEvent(service, data)
		}
	}
	for _, src := range added {
		if src.refresh != nil {
			src.refresh()
		}
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
// loop.
func (s *Server) Broadcast(service string, data any) {
	s.mu.RLock()
	targets := make([]*conn, 0, len(s.subscribers))
	for c, set := range s.subscribers {
		if set.covers(service) {
			targets = append(targets, c)
		}
	}
	s.mu.RUnlock()
	for _, c := range targets {
		c.sendEvent(service, data)
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
