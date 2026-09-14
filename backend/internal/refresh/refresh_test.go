package refresh

import (
	"testing"
	"time"
)

// idleWindow is how long a test waits before concluding no further run is
// coming. It is generous enough that a scheduling delay does not read as a
// missing run.
const idleWindow = 300 * time.Millisecond

func TestKicksDuringARunCollapseIntoOne(t *testing.T) {
	started := make(chan struct{}, 8)
	proceed := make(chan struct{})
	loop := newLoop(0, nil, func() {
		started <- struct{}{}
		<-proceed
	})
	t.Cleanup(loop.Close)

	loop.Kick()
	awaitRun(t, started, "first kick")

	// Five requests arrive while the first run holds the goroutine.
	for i := 0; i < 5; i++ {
		loop.Kick()
	}
	proceed <- struct{}{}
	awaitRun(t, started, "kicks received during a run")

	proceed <- struct{}{}
	select {
	case <-started:
		t.Fatal("five kicks during one run produced more than one follow-up run; a burst of signals would fork one external query each")
	case <-time.After(idleWindow):
	}
}

func TestCloseStopsFurtherRuns(t *testing.T) {
	started := make(chan struct{}, 4)
	loop := newLoop(0, nil, func() { started <- struct{}{} })

	loop.Kick()
	awaitRun(t, started, "kick before close")

	loop.Close()
	loop.Kick()
	select {
	case <-started:
		t.Fatal("the loop ran after Close; a closed service would keep forking commands after shutdown")
	case <-time.After(idleWindow):
	}

	// Close runs on shutdown paths that can overlap, so a second call must not
	// panic on an already-closed channel.
	loop.Close()
}

func TestDelayHoldsTheRunUntilTheWindowPasses(t *testing.T) {
	started := make(chan struct{}, 4)
	loop := newLoop(150*time.Millisecond, nil, func() { started <- struct{}{} })
	t.Cleanup(loop.Close)

	loop.Kick()
	select {
	case <-started:
		t.Fatal("the run began before its settle window elapsed; a burst of kicks would not have time to collapse")
	case <-time.After(50 * time.Millisecond):
	}
	awaitRun(t, started, "kick after its settle window")
}

func awaitRun(t *testing.T, started <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatalf("no run followed %s", what)
	}
}

// A Close that lands while a kick is settling must cancel that run. Otherwise
// the service forks its external command after shutdown: bluez would sweep a
// D-Bus connection its own Close is closing, and the others would fork nmcli,
// the brightness helper, lpstat or hyprctl.
func TestCloseDuringTheSettleWindowCancelsTheRun(t *testing.T) {
	const settle = 300 * time.Millisecond
	started := make(chan struct{}, 4)
	loop := newLoop(settle, nil, func() { started <- struct{}{} })

	loop.Kick()
	// Inside the settle window, so the run is pending and has not begun.
	time.Sleep(settle / 6)
	loop.Close()

	// Watch well past the point the window would have elapsed, or a run that
	// merely finishes its wait before starting would go unseen.
	select {
	case <-started:
		t.Fatal("the settling run went ahead after Close; the service would fork its external command after shutdown")
	case <-time.After(settle * 4):
	}
}

// A select whose cases are both ready picks between them uniformly, so a kick
// pending when Close lands takes the kick about half the time. The run must
// still not go ahead: at logout that is one more nmcli, lpstat, hyprctl or
// helper child per service, and for bluez a sweep of a D-Bus connection its own
// Close is shutting.
func TestNoRunStartsAfterClose(t *testing.T) {
	for _, row := range []struct {
		name  string
		delay time.Duration
	}{
		{"no settle window", 0},
		{"settle window already elapsed", time.Nanosecond},
	} {
		t.Run(row.name, func(t *testing.T) {
			// Many iterations: one pass proves nothing when the branch that
			// reaches the run is chosen at random.
			for i := 0; i < 500; i++ {
				l := &loop{
					kick:  make(chan struct{}, 1),
					stop:  make(chan struct{}),
					delay: row.delay,
				}
				// A kick already pending and stop already closed, so both cases
				// of the first select are ready.
				l.kick <- struct{}{}
				l.Close()

				ran := false
				l.loop(func() { ran = true })
				if ran {
					t.Fatalf("a run started after Close on iteration %d", i)
				}
			}
		})
	}
}

// Close runs on shutdown paths that can overlap, and it closes a channel.
func TestCloseIsSafeToRepeat(t *testing.T) {
	l := newLoop(0, nil, func() {})
	l.Close()
	l.Close()
}
