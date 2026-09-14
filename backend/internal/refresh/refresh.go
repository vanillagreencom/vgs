// Package refresh coalesces state-refresh requests onto one goroutine per
// service. A service whose state comes from external commands runs those
// commands here, off the caller's goroutine, so a burst of D-Bus signals or a
// run of subscribe frames costs one query instead of one per request.
package refresh

import (
	"sync"
	"time"
)

// Loop runs one refresh at a time. Kick asks for a run; requests arriving while
// one is already pending collapse into it. The zero value is not usable; use
// NewLoop.
type Loop struct {
	kick  chan struct{}
	stop  chan struct{}
	delay time.Duration
	once  sync.Once
}

// NewLoop starts the loop's goroutine. delay is the settle window between a
// kick and the run it triggers, which lets a burst of kicks collapse; a zero
// delay runs immediately. run is called with no lock held and must return.
func NewLoop(delay time.Duration, run func()) *Loop {
	l := &Loop{
		kick:  make(chan struct{}, 1),
		stop:  make(chan struct{}),
		delay: delay,
	}
	go l.loop(run)
	return l
}

// Kick requests a refresh. It never blocks: a request that arrives while one is
// already pending is subsumed by it.
func (l *Loop) Kick() {
	select {
	case l.kick <- struct{}{}:
	default:
	}
}

// Close stops the loop. A refresh already running finishes. Close is safe to
// call more than once, because a service's Close runs on shutdown paths that
// can overlap.
func (l *Loop) Close() {
	l.once.Do(func() { close(l.stop) })
}

func (l *Loop) loop(run func()) {
	for {
		select {
		case <-l.stop:
			return
		case <-l.kick:
		}
		if l.delay > 0 {
			select {
			case <-l.stop:
				return
			case <-time.After(l.delay):
			}
		}
		run()
	}
}
