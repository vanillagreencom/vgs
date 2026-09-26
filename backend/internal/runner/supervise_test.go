package runner

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

const supervisorBound = 5 * time.Second

// startLog records when the supervisor asked for each backend. Backend scripts
// can record their own pid in $PIDS.
type startLog struct {
	mu      sync.Mutex
	times   []time.Time
	pidPath string
}

func newStartLog(t *testing.T) *startLog {
	return &startLog{pidPath: filepath.Join(t.TempDir(), "backend.pids")}
}

func (s *startLog) command(script string) func() *exec.Cmd {
	return func() *exec.Cmd {
		s.mu.Lock()
		s.times = append(s.times, time.Now())
		s.mu.Unlock()
		cmd := exec.Command("/bin/sh", "-c", script)
		cmd.Env = []string{"PATH=/usr/bin:/bin", "PIDS=" + s.pidPath}
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

// awaitPIDs waits for n recorded backend pids and kills each one at cleanup.
func (s *startLog) awaitPIDs(t *testing.T, n int) []int {
	t.Helper()
	deadline := time.Now().Add(supervisorBound)
	for time.Now().Before(deadline) {
		data, _ := os.ReadFile(s.pidPath)
		var pids []int
		for _, field := range strings.Fields(string(data)) {
			pid, err := strconv.Atoi(field)
			if err != nil {
				t.Fatalf("%s holds %q, not a pid", s.pidPath, field)
			}
			pids = append(pids, pid)
		}
		if len(pids) >= n {
			t.Cleanup(func() {
				for _, pid := range pids {
					_ = syscall.Kill(pid, syscall.SIGKILL)
				}
			})
			return pids
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("backends did not record %d pid(s)", n)
	return nil
}

// syncBuffer is the supervisor's log, read by the test while it is written.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) count(msg string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return strings.Count(b.buf.String(), msg)
}

const tripMessage = "backend crash loop detected"

func (b *syncBuffer) await(t *testing.T, msg string, n int) {
	t.Helper()
	deadline := time.Now().Add(supervisorBound)
	for time.Now().Before(deadline) {
		if b.count(msg) >= n {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("log holds %q %d time(s), want %d", msg, b.count(msg), n)
}

func testLimits() supervisionLimits {
	return supervisionLimits{
		backoffInitial:  time.Millisecond,
		backoffMax:      time.Millisecond,
		breakerWindow:   time.Minute,
		breakerLimit:    3,
		cooldownInitial: 300 * time.Millisecond,
		cooldownMax:     time.Hour,
		stopGrace:       time.Second,
	}
}

type supervisorRun struct {
	restart chan<- os.Signal
	ln      *net.UnixListener
	logs    *syncBuffer
	// stop closes the stop channel once and reports whether supervise returned
	// within supervisorBound.
	stop func() bool
}

func newListener(t *testing.T) *net.UnixListener {
	t.Helper()
	// A short directory keeps the socket path inside the Unix address limit.
	dir, err := os.MkdirTemp("", "vgs")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: filepath.Join(dir, "s"), Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln
}

func runSupervisor(t *testing.T, command func() *exec.Cmd, limits supervisionLimits) supervisorRun {
	t.Helper()
	return runSupervisorOn(t, newListener(t), command, limits)
}

func runSupervisorOn(t *testing.T, ln *net.UnixListener, command func() *exec.Cmd, limits supervisionLimits) supervisorRun {
	t.Helper()
	stop := make(chan struct{})
	restart := make(chan os.Signal, 1)
	done := make(chan struct{})
	logs := &syncBuffer{}
	go func() {
		supervise(command, ln, limits, stop, restart, slog.New(slog.NewTextHandler(logs, nil)))
		close(done)
	}()
	var once sync.Once
	returned := false
	stopRun := func() bool {
		once.Do(func() {
			close(stop)
			select {
			case <-done:
				returned = true
			case <-time.After(supervisorBound):
			}
		})
		return returned
	}
	t.Cleanup(func() {
		if !stopRun() {
			t.Error("supervisor did not return after stop")
		}
	})
	return supervisorRun{restart: restart, ln: ln, logs: logs, stop: stopRun}
}

// TestSupervisorCoolDownDoublesAndStartsAgain checks that a crash loop holds
// the backend down for the cool-down and then starts it again, instead of
// ending supervision for the session, and that the next trip waits twice as
// long.
func TestSupervisorCoolDownDoublesAndStartsAgain(t *testing.T) {
	limits := testLimits()
	starts := newStartLog(t)
	runSupervisor(t, starts.command("exit 1"), limits)

	times := starts.await(t, 2*limits.breakerLimit+1)

	for i := 1; i < limits.breakerLimit; i++ {
		if gap := times[i].Sub(times[i-1]); gap >= limits.cooldownInitial {
			t.Fatalf("start %d came %v after the previous one; the breaker tripped before %d exits", i+1, gap, limits.breakerLimit)
		}
	}
	trips := []struct {
		start int
		want  time.Duration
	}{
		{start: limits.breakerLimit, want: limits.cooldownInitial},
		{start: 2 * limits.breakerLimit, want: 2 * limits.cooldownInitial},
	}
	for _, trip := range trips {
		if gap := times[trip.start].Sub(times[trip.start-1]); gap < trip.want {
			t.Fatalf("start %d came %v after the last exit, want at least the %v cool-down", trip.start+1, gap, trip.want)
		}
	}
}

func TestSupervisorRestartReplacesARunningBackend(t *testing.T) {
	starts := newStartLog(t)
	run := runSupervisor(t, starts.command(`echo $$ >> "$PIDS"; exec sleep 60`), testLimits())
	first := starts.awaitPIDs(t, 1)[0]

	run.restart <- os.Interrupt

	starts.await(t, 2)
	deadline := time.Now().Add(supervisorBound)
	for syscall.Kill(first, 0) == nil {
		if time.Now().After(deadline) {
			t.Fatalf("backend pid %d still runs after the restart started its replacement", first)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestSupervisorRestartCutsACoolDownShort(t *testing.T) {
	limits := testLimits()
	limits.cooldownInitial = time.Hour
	starts := newStartLog(t)
	run := runSupervisor(t, starts.command("exit 1"), limits)
	run.logs.await(t, tripMessage, 1)
	if got := len(starts.snapshot()); got != limits.breakerLimit {
		t.Fatalf("supervisor made %d start(s) before the cool-down, want %d", got, limits.breakerLimit)
	}

	run.restart <- os.Interrupt

	starts.await(t, limits.breakerLimit+1)
}

// TestSupervisorClosesConnectionsDuringACoolDown checks that a client connecting
// while the backend is held down is closed at once, and that nothing it queued
// is left for the next backend to accept.
func TestSupervisorClosesConnectionsDuringACoolDown(t *testing.T) {
	limits := testLimits()
	limits.cooldownInitial = time.Hour
	starts := newStartLog(t)
	healthy := filepath.Join(t.TempDir(), "healthy")
	run := runSupervisor(t, starts.command(fmt.Sprintf(`[ -e '%s' ] && exec sleep 60; exit 1`, healthy)), limits)
	run.logs.await(t, tripMessage, 1)

	conn, err := net.Dial("unix", run.ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("{\"id\":1,\"method\":\"getServerInfo\"}\n")); err != nil && !errors.Is(err, syscall.EPIPE) {
		t.Fatal(err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(supervisorBound))
	n, err := conn.Read(make([]byte, 64))
	if n != 0 || !(errors.Is(err, io.EOF) || errors.Is(err, syscall.ECONNRESET)) {
		t.Fatalf("read during the cool-down = (%d, %v), want the connection closed with no data", n, err)
	}

	if err := os.WriteFile(healthy, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	run.restart <- os.Interrupt
	starts.await(t, limits.breakerLimit+1)

	_ = run.ln.SetDeadline(time.Now().Add(300 * time.Millisecond))
	if queued, err := run.ln.Accept(); err == nil {
		queued.Close()
		t.Fatal("the next backend could accept a connection made during the cool-down")
	}
}

// TestSupervisorCoolDownEndsWithABlockingListener hands the listener to every
// backend the way the runner does. Handing it over leaves the listener in
// blocking mode when a backend exits without reopening it, and a restart and a
// stop during the cool-down must still return.
func TestSupervisorCoolDownEndsWithABlockingListener(t *testing.T) {
	limits := testLimits()
	limits.cooldownInitial = time.Hour
	ln := newListener(t)
	lnFile, err := ln.File()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { lnFile.Close() })
	starts := newStartLog(t)
	backend := starts.command("exit 1")
	run := runSupervisorOn(t, ln, func() *exec.Cmd {
		cmd := backend()
		cmd.ExtraFiles = []*os.File{lnFile}
		return cmd
	}, limits)
	run.logs.await(t, tripMessage, 1)

	run.restart <- os.Interrupt
	starts.await(t, limits.breakerLimit+1)
	run.logs.await(t, tripMessage, 2)

	if !run.stop() {
		t.Fatal("supervisor did not return after stop during a cool-down")
	}
}
