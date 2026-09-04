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

// HandlerFunc handles one method call. It receives raw params and returns a
// JSON-serializable result or an error surfaced to the client.
type HandlerFunc func(params json.RawMessage) (any, error)

// Server is a running daemon. The zero value is not usable; use New.
type Server struct {
	log *slog.Logger
	uid uint32

	mu           sync.RWMutex
	handlers     map[string]HandlerFunc
	capabilities map[string]bool
	snapshots    map[string]func() any
	subscribers  map[*conn]map[string]bool

	workersMu sync.Mutex
	workers   map[string]chan func()

	// sendQueue orders broadcast delivery and computes subscription snapshots at
	// dispatch. Queue order keeps each snapshot after broadcasts submitted ahead of
	// it.
	sendQueue chan func()
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
		capabilities: map[string]bool{"core": true},
		snapshots:    map[string]func() any{},
		subscribers:  map[*conn]map[string]bool{},
		workers:      map[string]chan func(){},
		sendQueue:    make(chan func(), 256),
	}
	go func() {
		for job := range s.sendQueue {
			job()
		}
	}()
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

// RegisterSnapshot adds current state emitted immediately after subscribe.
// Unknown requested services remain tolerated; snapshots are best-effort.
func (s *Server) RegisterSnapshot(service string, snapshot func() any) {
	if service == "" || snapshot == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.snapshots[service] = snapshot
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
	s.mu.RUnlock()

	if !known || h == nil {
		c.send(protocol.Response{ID: req.ID, Error: "unknown method: " + req.Method})
		return
	}
	// Each method has a worker so a slow handler does not hold the read goroutine.
	// Calls to the same method stay in order. A full method queue can still block
	// the connection read loop.
	s.enqueue(req.Method, func() {
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
	})
}

// enqueue runs job on the method's FIFO worker, creating it on first use. The
// send blocks (backpressuring the connection's read loop) if a method somehow
// accumulates a full queue of outstanding calls.
func (s *Server) enqueue(method string, job func()) {
	s.workersMu.Lock()
	ch, ok := s.workers[method]
	if !ok {
		ch = make(chan func(), 64)
		s.workers[method] = ch
		go func() {
			for j := range ch {
				s.runJob(method, j)
			}
		}()
	}
	s.workersMu.Unlock()
	ch <- job
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

	set := map[string]bool{}
	for _, svc := range p.Services {
		set[svc] = true
	}
	s.mu.Lock()
	s.subscribers[c] = set
	s.mu.Unlock()

	// Compute subscription snapshots in the send queue so earlier queued broadcasts
	// cannot follow them.
	s.sendQueue <- func() {
		c.send(protocol.Response{Result: protocol.Event{Service: "server", Data: s.info()}})

		s.mu.RLock()
		snapshots := make(map[string]func() any, len(s.snapshots))
		for service, snapshot := range s.snapshots {
			if set[service] || set["all"] || len(set) == 0 {
				snapshots[service] = snapshot
			}
		}
		s.mu.RUnlock()
		for service, snapshot := range snapshots {
			c.send(protocol.Response{Result: protocol.Event{Service: service, Data: snapshot()}})
		}
	}
}

func (s *Server) dropSubscriber(c *conn) {
	s.mu.Lock()
	delete(s.subscribers, c)
	s.mu.Unlock()
}

// Broadcast pushes an event to every connection subscribed to service (or to
// "all"). Services call this as their state changes; delivery is asynchronous
// through the ordered send queue.
func (s *Server) Broadcast(service string, data any) {
	s.sendQueue <- func() {
		ev := protocol.Response{Result: protocol.Event{Service: service, Data: data}}
		s.mu.RLock()
		targets := make([]*conn, 0, len(s.subscribers))
		for c, set := range s.subscribers {
			if set[service] || set["all"] || len(set) == 0 {
				targets = append(targets, c)
			}
		}
		s.mu.RUnlock()
		for _, c := range targets {
			c.send(ev)
		}
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
