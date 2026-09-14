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
	loop := newLoop(0, func() {
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
	loop := newLoop(0, func() { started <- struct{}{} })

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
	loop := newLoop(150*time.Millisecond, func() { started <- struct{}{} })
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
	loop := newLoop(settle, func() { started <- struct{}{} })

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
