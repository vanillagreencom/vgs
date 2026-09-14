package refresh

import (
	"log/slog"
	"sync"
	"time"
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
}

// Record stores the result of a successful query. A failed query records
// nothing, so the last-known-good state stands.
func (s *Source[T]) Record(value T) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.value = value
	s.recorded = true
}

// Cached returns the newest recorded value, or nil before the first Record.
// Nil means the service has nothing to report yet and subscribe sends no frame
// for it: an empty state would reach the shell as fact and blank a list the
// kicked refresh is about to fill.
func (s *Source[T]) Cached() any {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.recorded {
		return nil
	}
	return s.value
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
	s.loop = newLoop(settle, s.refreshAndBroadcast)
	return s
}

// Kick asks for a refresh on the service's own goroutine. It returns without
// waiting for the query, so subscribe can call it.
func (s *Service[T]) Kick() { s.loop.Kick() }

// Query runs the live query on the calling goroutine and records a success, so
// a method handler warms what the next subscribe reads. Never call it from the
// subscribe path, where it would stall every other service behind it.
func (s *Service[T]) Query() (T, error) {
	value, err := s.query()
	if err != nil {
		return value, err
	}
	s.Record(value)
	return value, nil
}

// Close stops the refresh goroutine. A query already running finishes.
func (s *Service[T]) Close() { s.loop.Close() }

func (s *Service[T]) refreshAndBroadcast() {
	value, err := s.Query()
	if err != nil {
		// Keep the subscribers' last-known state rather than publishing an
		// empty one as truth.
		s.log.Warn("state refresh failed, skipping broadcast", "service", s.service, "err", err)
		return
	}
	s.srv.Broadcast(s.service, value)
}
