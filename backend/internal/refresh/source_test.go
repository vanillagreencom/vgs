package refresh

import (
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"
)

func discardLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

// recorder captures what a service publishes.
type recorder struct {
	mu     sync.Mutex
	frames []any
}

func (r *recorder) Broadcast(_ string, data any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.frames = append(r.frames, data)
}

func (r *recorder) all() []any {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]any(nil), r.frames...)
}

func (r *recorder) await(t *testing.T, want int) []any {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if got := r.all(); len(got) >= want {
			return got
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("only %d broadcasts arrived, want %d", len(r.all()), want)
	return nil
}

func TestSourceHoldsNothingBeforeItsFirstRecord(t *testing.T) {
	var s Source[string]
	if got := s.Cached(); got != nil {
		t.Fatalf("Cached = %v before any record, want nothing to send", got)
	}
	s.Record("state")
	if got := s.Cached(); got != "state" {
		t.Fatalf("Cached = %v, want the recorded value", got)
	}
}

func TestServiceQueryRecordsOnlyOnSuccess(t *testing.T) {
	failing := errors.New("command unreachable")
	var result string
	var err error
	svc := NewService[string](&recorder{}, discardLogger(), "svc", 0, func() (string, error) {
		return result, err
	})
	t.Cleanup(svc.Close)

	result, err = "", failing
	if _, got := svc.Query(); !errors.Is(got, failing) {
		t.Fatalf("Query error = %v, want the query's own error", got)
	}
	if got := svc.Cached(); got != nil {
		t.Fatalf("a failed query recorded %v; an empty state must not become the shell's truth", got)
	}

	result, err = "fresh", nil
	if got, qerr := svc.Query(); qerr != nil || got != "fresh" {
		t.Fatalf("Query = (%v, %v), want the query's result", got, qerr)
	}
	if got := svc.Cached(); got != "fresh" {
		t.Fatalf("Cached = %v after a successful query, want it warmed", got)
	}
}

func TestServiceKickRecordsAndBroadcasts(t *testing.T) {
	srv := &recorder{}
	svc := NewService[string](srv, discardLogger(), "svc", 0, func() (string, error) { return "fresh", nil })
	t.Cleanup(svc.Close)

	svc.Kick()
	if got := srv.await(t, 1); got[0] != "fresh" {
		t.Fatalf("broadcast payload = %v, want the query result", got[0])
	}
	if got := svc.Cached(); got != "fresh" {
		t.Fatalf("Cached = %v after a kick, want it warmed", got)
	}
}

func TestServiceFailedRefreshBroadcastsNothing(t *testing.T) {
	srv := &recorder{}
	svc := NewService[string](srv, discardLogger(), "svc", 0, func() (string, error) {
		return "", errors.New("command unreachable")
	})
	t.Cleanup(svc.Close)

	svc.Kick()
	time.Sleep(idleWindow)
	if got := srv.all(); len(got) != 0 {
		t.Fatalf("a failed refresh broadcast %v; subscribers must keep their last-known state", got)
	}
}
