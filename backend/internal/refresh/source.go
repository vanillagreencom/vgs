package refresh

import (
	"log/slog"
	"sync"
	"time"

	"vshell/backend/internal/recovery"
)

// Broadcaster is the part of the daemon a refreshed service publishes through.
type Broadcaster interface {
	Broadcast(service string, data any)
}

// Source is a service's last-known-good state. The query path records into it
// and subscribe reads it, so a snapshot never runs a live query on the
// subscribing connection.
//
// The zero value is ready to use and holds nothing yet.
type Source[T any] struct {
	mu       sync.Mutex
	value    T
	recorded bool
	// issued numbers each query as it starts and held is the number of the one
	// whose result is recorded. Queries run on whichever goroutine calls them,
	// so two can be in flight at once and can finish in the other order; the
	// numbers keep the cache moving forward instead of letting a sweep that
	// started earlier overwrite a newer one.
	issued uint64
	held   uint64
}

// Query runs query on the calling goroutine and records a success. A result
// that a later-started query has already superseded is returned to its caller
// and dropped from the cache. A failed query records nothing, so the
// last-known-good state stands.
func (s *Source[T]) Query(query func() (T, error)) (T, error) {
	s.mu.Lock()
	s.issued++
	mine := s.issued
	s.mu.Unlock()

	value, err := query()
	if err != nil {
		return value, err
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.recorded && mine <= s.held {
		return value, nil
	}
	s.value = value
	s.recorded = true
	s.held = mine
	return value, nil
}

// hasIssued reports whether any query has started. The very first query of a
// service's life has nothing to debounce against, but every later one does,
// including a retry after a failure: keying this on success instead would leave
// a service whose query keeps failing running its external command on every
// kick, with no settle window at all.
func (s *Source[T]) hasIssued() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.issued > 0
}

// Value returns the newest recorded value and whether any query has recorded
// one. It is the typed form of Cached, for a caller that needs the value back
// as T rather than as a snapshot payload.
func (s *Source[T]) Value() (T, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.value, s.recorded
}

// Cached returns the newest recorded value, or nil before the first successful
// query. Nil means the service has nothing to report yet and subscribe sends no
// frame for it: an empty state would reach the shell as fact and blank a list
// the kicked refresh is about to fill.
func (s *Source[T]) Cached() any {
	value, recorded := s.Value()
	if !recorded {
		return nil
	}
	return value
}

// Service couples a service's live query to one refresh goroutine and to the
// state subscribe reads. It owns the whole contract: a kick coalesces onto the
// loop, a success is recorded and broadcast, and a failure is logged while the
// recorded state stands.
//
// The zero value is not usable; use NewService.
type Service[T any] struct {
	Source[T]

	srv     Broadcaster
	log     *slog.Logger
	service string
	query   func() (T, error)
	loop    *loop
}

// NewService starts the refresh goroutine for service. query must not record
// into the source itself: every path that records goes through this type, so
// there is one place that decides what a successful query means. settle is the
// window a burst of kicks collapses into, as described on newLoop.
//
// The returned Service is ready before any goroutine can reach it, so a service
// may install its signal watches and register its methods afterwards.
func NewService[T any](srv Broadcaster, log *slog.Logger, service string, settle time.Duration, query func() (T, error)) *Service[T] {
	if log == nil {
		log = slog.Default()
	}
	s := &Service[T]{srv: srv, log: log, service: service, query: query}
	// Nothing queried yet means no burst to collapse and no state to serve, so
	// the first query runs at once rather than a settle window late.
	s.loop = newLoop(settle, func() bool { return !s.hasIssued() }, func() {
		recovery.Run(s.log, "refresh "+service, s.refreshAndBroadcast)
	})
	return s
}

// Kick asks for a refresh on the service's own goroutine. It returns without
// waiting for the query, so subscribe can call it.
func (s *Service[T]) Kick() { s.loop.Kick() }

// Query runs the live query on the calling goroutine and records a success, so
// a method handler warms what the next subscribe reads. Never call it from the
// subscribe path, where it would stall every other service behind it.
func (s *Service[T]) Query() (T, error) { return s.Source.Query(s.query) }

// Close stops the refresh goroutine. A query already running finishes.
func (s *Service[T]) Close() { s.loop.Close() }

func (s *Service[T]) refreshAndBroadcast() {
	if _, err := s.Query(); err != nil {
		// Keep the subscribers' last-known state rather than publishing an
		// empty one as truth.
		s.log.Warn("state refresh failed, skipping broadcast", "service", s.service, "err", err)
		return
	}
	// The recorded state, not what this query returned: a query that a
	// later-started one superseded still publishes, and must publish the newer
	// state, or the cache and the wire disagree and the wire is what the shell
	// applies. The winning query may have been a handler that broadcasts
	// nothing, so this one still sends.
	state := s.Cached()
	if state == nil {
		return
	}
	s.srv.Broadcast(s.service, state)
}
