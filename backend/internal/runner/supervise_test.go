package runner

import (
	"io"
	"log/slog"
	"os"
	"os/exec"
	"sync"
	"testing"
	"time"
)

const supervisorBound = 5 * time.Second

// startLog records when the supervisor asked for each backend.
type startLog struct {
	mu    sync.Mutex
	times []time.Time
}

func (s *startLog) command(script string) func() *exec.Cmd {
	return func() *exec.Cmd {
		s.mu.Lock()
		s.times = append(s.times, time.Now())
		s.mu.Unlock()
		cmd := exec.Command("/bin/sh", "-c", script)
		cmd.Env = []string{"PATH=/usr/bin:/bin"}
		return cmd
	}
}

func (s *startLog) snapshot() []time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]time.Time(nil), s.times...)
}

func (s *startLog) await(t *testing.T, n int) []time.Time {
	t.Helper()
	deadline := time.Now().Add(supervisorBound)
	for time.Now().Before(deadline) {
		if got := s.snapshot(); len(got) >= n {
			return got
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("supervisor made %d start(s), want %d", len(s.snapshot()), n)
	return nil
}

func testLimits() supervisionLimits {
	return supervisionLimits{
		backoffInitial:  time.Millisecond,
		backoffMax:      time.Millisecond,
		breakerWindow:   time.Minute,
		breakerLimit:    3,
		cooldownInitial: 500 * time.Millisecond,
		cooldownMax:     time.Hour,
		stopGrace:       time.Second,
	}
}

func runSupervisor(t *testing.T, command func() *exec.Cmd, limits supervisionLimits) chan<- os.Signal {
	t.Helper()
	stop := make(chan struct{})
	restart := make(chan os.Signal, 1)
	done := make(chan struct{})
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	go func() {
		supervise(command, limits, stop, restart, log)
		close(done)
	}()
	t.Cleanup(func() {
		close(stop)
		select {
		case <-done:
		case <-time.After(supervisorBound):
			t.Error("supervisor did not return after stop")
		}
	})
	return restart
}

// TestSupervisorStartsAgainAfterTheCoolDown checks that a crash loop holds the
// backend down for the cool-down and then starts it again, instead of ending
// supervision for the session.
func TestSupervisorStartsAgainAfterTheCoolDown(t *testing.T) {
	limits := testLimits()
	var starts startLog
	runSupervisor(t, starts.command("exit 1"), limits)

	times := starts.await(t, limits.breakerLimit+1)

	for i := 1; i < limits.breakerLimit; i++ {
		if gap := times[i].Sub(times[i-1]); gap >= limits.cooldownInitial {
			t.Fatalf("start %d came %v after the previous one; the breaker tripped before %d exits", i+1, gap, limits.breakerLimit)
		}
	}
	if gap := times[limits.breakerLimit].Sub(times[limits.breakerLimit-1]); gap < limits.cooldownInitial {
		t.Fatalf("start after the breaker tripped came %v after the last exit, want at least the %v cool-down", gap, limits.cooldownInitial)
	}
}

func TestSupervisorRestartRequest(t *testing.T) {
	cases := []struct {
		name string
		// script is the backend's body.
		script string
		// before is the start count at which the request is sent.
		before   int
		cooldown time.Duration
	}{
		{name: "replaces a running backend", script: "exec sleep 60", before: 1, cooldown: time.Hour},
		{name: "cuts a cool-down short", script: "exit 1", before: testLimits().breakerLimit, cooldown: time.Hour},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			limits := testLimits()
			limits.cooldownInitial = tc.cooldown
			var starts startLog
			restart := runSupervisor(t, starts.command(tc.script), limits)
			starts.await(t, tc.before)
			time.Sleep(100 * time.Millisecond)
			if got := len(starts.snapshot()); got != tc.before {
				t.Fatalf("supervisor made %d start(s) before the request, want %d", got, tc.before)
			}

			restart <- os.Interrupt

			starts.await(t, tc.before+1)
		})
	}
}
