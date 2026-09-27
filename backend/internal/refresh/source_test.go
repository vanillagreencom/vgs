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

func TestSourceHoldsNothingBeforeItsFirstQuery(t *testing.T) {
	var s Source[string]
	if got := s.Cached(); got != nil {
		t.Fatalf("Cached = %v before any query, want nothing to send", got)
	}
	if _, err := s.Query(func() (string, error) { return "state", nil }); err != nil {
		t.Fatalf("Query: %v", err)
	}
	if got := s.Cached(); got != "state" {
		t.Fatalf("Cached = %v, want the recorded value", got)
	}
}

// Queries run on whichever goroutine calls them, so a service with several
// method workers can have two sweeps in flight. A sweep that started earlier
// and finished later must not overwrite the newer one, or the next subscribe
// serves state from before the change that prompted it.
func TestSourceKeepsTheLaterStartedQueryWhenTheyFinishOutOfOrder(t *testing.T) {
	var s Source[string]
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	done := make(chan struct{}, 2)

	go func() {
		_, _ = s.Query(func() (string, error) {
			close(firstStarted)
			<-releaseFirst
			return "older sweep", nil
		})
		done <- struct{}{}
	}()

	<-firstStarted
	// Starts second and finishes first.
	if _, err := s.Query(func() (string, error) { return "newer sweep", nil }); err != nil {
		t.Fatalf("second query: %v", err)
	}
	close(releaseFirst)
	<-done

	if got := s.Cached(); got != "newer sweep" {
		t.Fatalf("Cached = %v; the sweep that started first overwrote the newer one", got)
	}
}

// Its own caller still receives what its query returned; only the cache drops
// the superseded value.
func TestSourceReturnsASupersededResultToItsCaller(t *testing.T) {
	var s Source[string]
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	got := make(chan string, 1)

	go func() {
		value, _ := s.Query(func() (string, error) {
			close(firstStarted)
			<-releaseFirst
			return "older sweep", nil
		})
		got <- value
	}()

	<-firstStarted
	if _, err := s.Query(func() (string, error) { return "newer sweep", nil }); err != nil {
		t.Fatalf("second query: %v", err)
	}
	close(releaseFirst)

	select {
	case value := <-got:
		if value != "older sweep" {
			t.Fatalf("superseded caller received %q, want its own query's result", value)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the superseded query never returned")
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

// A query that panics must cost that run only: the loop keeps serving kicks, so
// a fault in one service's parser does not leave its state frozen.
func TestServiceKeepsRefreshingAfterAQueryPanics(t *testing.T) {
	srv := &recorder{}
	var mu sync.Mutex
	calls := 0
	svc := NewService[string](srv, discardLogger(), "svc", 0, func() (string, error) {
		mu.Lock()
		calls++
		first := calls == 1
		mu.Unlock()
		if first {
			panic("parser fault")
		}
		return "fresh", nil
	})
	t.Cleanup(svc.Close)

	svc.Kick()
	time.Sleep(idleWindow)
	svc.Kick()

	if got := srv.await(t, 1); got[0] != "fresh" {
		t.Fatalf("broadcast payload = %v, want the query result from the run after the panic", got[0])
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

// With nothing recorded there is no burst to collapse and no state to serve, so
// the first kick runs at once. Waiting the settle window would put the first
// frame the shell sees a window late on every shell start and reconnect.
func TestServiceFirstKickRunsWithoutWaitingTheSettleWindow(t *testing.T) {
	const settle = 2 * time.Second
	started := make(chan struct{}, 4)
	svc := NewService[string](&recorder{}, discardLogger(), "svc", settle, func() (string, error) {
		started <- struct{}{}
		return "fresh", nil
	})
	t.Cleanup(svc.Close)

	svc.Kick()
	select {
	case <-started:
	case <-time.After(settle / 2):
		t.Fatal("the first kick waited the settle window; the shell sees its first state a window late on every start")
	}
}

// Once state is recorded the window is back, so a burst of kicks collapses.
func TestServiceSettlesOnceSomethingIsRecorded(t *testing.T) {
	const settle = 400 * time.Millisecond
	started := make(chan struct{}, 8)
	svc := NewService[string](&recorder{}, discardLogger(), "svc", settle, func() (string, error) {
		started <- struct{}{}
		return "fresh", nil
	})
	t.Cleanup(svc.Close)

	svc.Kick()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("the first kick never ran")
	}

	svc.Kick()
	select {
	case <-started:
		t.Fatal("a kick against recorded state ran before its settle window; a burst would no longer collapse")
	case <-time.After(settle / 4):
	}
}

// The wire must carry what the cache holds. A refresh sweep that started first
// and finished last is dropped from the cache, but it still broadcasts, and
// broadcasting its own older result would put that on the wire as the last
// frame the shell applies.
func TestServiceBroadcastsTheRecordedStateNotASupersededOne(t *testing.T) {
	srv := &recorder{}
	refreshStarted := make(chan struct{})
	releaseRefresh := make(chan struct{})
	svc := NewService[string](srv, discardLogger(), "svc", 0, func() (string, error) {
		close(refreshStarted)
		<-releaseRefresh
		return "older sweep", nil
	})
	t.Cleanup(svc.Close)

	svc.Kick()
	<-refreshStarted
	// A handler query that starts second and finishes first, as a method worker
	// running beside the refresh loop does.
	if _, err := svc.Source.Query(func() (string, error) { return "newer sweep", nil }); err != nil {
		t.Fatalf("handler query: %v", err)
	}
	close(releaseRefresh)

	frames := srv.await(t, 1)
	for _, frame := range frames {
		if frame == "older sweep" {
			t.Fatalf("a superseded sweep published its own result: %v", frames)
		}
	}
	if frames[len(frames)-1] != "newer sweep" {
		t.Fatalf("broadcast %v, want the recorded state", frames)
	}
	if got := svc.Cached(); got != frames[len(frames)-1] {
		t.Fatalf("the wire carried %v while the cache holds %v", frames[len(frames)-1], got)
	}
}

// A query that keeps failing records nothing. Keying the skip on success would
// leave the settle window off forever, so every kick would fork the service's
// external command while the panel stays empty.
func TestServiceSettlesAfterAFailingQuery(t *testing.T) {
	const settle = 400 * time.Millisecond
	started := make(chan struct{}, 64)
	svc := NewService[string](&recorder{}, discardLogger(), "svc", settle, func() (string, error) {
		started <- struct{}{}
		return "", errors.New("command unreachable")
	})
	t.Cleanup(svc.Close)

	svc.Kick()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("the first kick never ran")
	}

	svc.Kick()
	select {
	case <-started:
		t.Fatal("a kick after a failed query ran with no settle window; a burst would fork the command on every kick")
	case <-time.After(settle / 4):
	}
}
