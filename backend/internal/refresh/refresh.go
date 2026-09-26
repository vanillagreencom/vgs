// Package refresh holds a service's last-known-good state and the goroutine
// that refreshes it. A kick coalesces onto that goroutine, so a burst of D-Bus
// signals or a run of subscribe frames costs one query instead of one per
// request.
//
// Only kicked refreshes run on that goroutine. Query runs on whichever
// goroutine calls it, which is how a method handler warms the cache, so two
// queries for one service can be in flight at once and can finish in the other
// order. Source numbers them and keeps the newer result.
package refresh

import (
	"sync"
	"time"
)

// loop runs one refresh at a time. Kick asks for a run; requests arriving while
// one is already pending collapse into it. The zero value is not usable; use
// newLoop.
type loop struct {
	kick  chan struct{}
	stop  chan struct{}
	delay time.Duration
	// skipSettle decides, at the moment a kick wakes the loop, whether this run
	// goes ahead immediately instead of settling first. It may be nil, which
	// always settles.
	skipSettle func() bool

	// mu guards closed, which is the one thing that decides whether a run goes
	// ahead. The selects below can find stop and their other case ready at the
	// same moment, and Go picks between ready cases uniformly, so neither is a
	// reliable stop on its own.
	mu     sync.Mutex
	closed bool
}

// newLoop starts the loop's goroutine. delay is the settle window between a
// kick and the run it triggers, which lets a burst of kicks collapse; a zero
// delay runs immediately. skipSettle, when it returns true as a kick wakes the
// loop, spends that run at once instead: a burst that arrives during the run or
// during the next window still collapses, so the window buys nothing on a run
// that has nothing to collapse against. run is called with no lock held and
// must return.
func newLoop(delay time.Duration, skipSettle func() bool, run func()) *loop {
	l := &loop{
		kick:       make(chan struct{}, 1),
		stop:       make(chan struct{}),
		delay:      delay,
		skipSettle: skipSettle,
	}
	go l.loop(run)
	return l
}

// Kick requests a refresh. It never blocks: a request that arrives while one is
// already pending is subsumed by it.
func (l *loop) Kick() {
	select {
	case l.kick <- struct{}{}:
	default:
	}
}

// Close stops the loop. A refresh already running finishes. Close is safe to
// call more than once, because a service's Close runs on shutdown paths that
// can overlap.
func (l *loop) Close() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return
	}
	l.closed = true
	close(l.stop)
}

func (l *loop) isClosed() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.closed
}

func (l *loop) loop(run func()) {
	for {
		select {
		case <-l.stop:
			return
		case <-l.kick:
		}
		if l.delay > 0 && (l.skipSettle == nil || !l.skipSettle()) {
			select {
			case <-l.stop:
				return
			case <-time.After(l.delay):
			}
		}
		// The selects above only decide when to get here; either can pick its
		// non-stop case while Close is landing. This is the single decision to
		// run, and it takes the same lock Close does, so a Close that returned
		// before this check is always seen here. A Close landing after it
		// finishes alongside the run it did not stop, which is a read-only
		// sweep.
		if l.isClosed() {
			return
		}
		// Subsume a kick that arrived during the window. The run about to start
		// reads the same state that kick was asking about, so leaving it
		// buffered would spend a second sweep on it and the window would
		// collapse nothing. A kick that arrives during the run stays buffered
		// and gets its own follow-up.
		select {
		case <-l.kick:
		default:
		}
		run()
	}
}
