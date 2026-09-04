package tailscale

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"vshell/backend/internal/server"
)

// The fixture contains concatenated, formatted JSON after a banner. Its
// placeholder private key checks that notification contents do not reach
// broadcasts or logs.
const ipnFrames = `Connected.
{
	"Version": "1.98.10",
	"State": 1,
	"Prefs": {
		"WantRunning": false,
		"Config": {
			"PrivateNodeKey": "privkey:0000000000000000000000000000000000000000000000000000000000000000"
		}
	}
}
{
	"Version": "1.98.10",
	"State": 6,
	"NetMap": { "Peers": [] }
}
{
	"Version": "1.98.10",
	"State": 6
}
`

const stoppedStatusFixture = `{
  "Version": "1.98.10",
  "BackendState": "NoState",
  "Self": { "ID": "self-id", "HostName": "laptop", "TailscaleIPs": ["100.64.0.1"] },
  "Peer": {}
}`

func TestReadFramesPulsesOncePerNotification(t *testing.T) {
	m := &Manager{}
	m.watchCtx, m.watchStop = context.WithCancel(context.Background())
	t.Cleanup(m.watchStop)

	var pulses atomic.Int32

	if err := m.readFrames(strings.NewReader(ipnFrames), func() { pulses.Add(1) }); err != nil {
		t.Fatalf("readFrames: %v", err)
	}
	if got := pulses.Load(); got != 3 {
		t.Fatalf("pulses = %d, want 3 (banner skipped, one per JSON value)", got)
	}
}

// TestPulseIsNotStarvedBySustainedTraffic checks that a stream faster than the
// coalescing window cannot postpone every push.
func TestPulseIsNotStarvedBySustainedTraffic(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	writeFile(t, statusPath, statusFixture)

	// Frames arrive faster than the coalescing window to expose a timer that
	// re-arms on each frame.
	stub := filepath.Join(dir, "tailscale")
	writeStub(t, stub, statusPath,
		"  printf 'Connected.\\n'\n"+
			"  while :; do printf '{\\n\\t\"State\": 6\\n}\\n'; sleep 0.05; done\n")

	srv, sock := startTestServer(t)
	m := newWatchManager(t, srv, stub)
	m.startWatch()

	c, sc := subscribeTailscale(t, sock)
	_ = readEvent(t, c, sc, "tailscale") // subscribe snapshot

	// The deadline must allow a pending push but expire while the frame stream
	// remains active.
	start := time.Now()
	update := readEvent(t, c, sc, "tailscale")
	elapsed := time.Since(start)
	if elapsed > 3*time.Second {
		t.Fatalf("first push under sustained traffic took %v, want <= 3s", elapsed)
	}
	if update["backendState"] != "Running" {
		t.Fatalf("pushed state = %v, want Running", update)
	}

	start = time.Now()
	_ = readEvent(t, c, sc, "tailscale")
	if elapsed := time.Since(start); elapsed > 4*time.Second {
		t.Fatalf("second push under sustained traffic took %v, want <= 4s", elapsed)
	}
}

// TestPulseHonoursMinIntervalFloor proves the two delays combine by taking the
// larger, so the min-interval floor can only lengthen the wait.
func TestPulseHonoursMinIntervalFloor(t *testing.T) {
	m := &Manager{}
	m.watchCtx, m.watchStop = context.WithCancel(context.Background())
	t.Cleanup(m.watchStop)

	m.lastPush = time.Now()
	m.pulse()
	m.watchMu.Lock()
	pending := m.pushTimer != nil
	m.watchMu.Unlock()
	if !pending {
		t.Fatal("pulse did not schedule a push")
	}
	// A second frame inside the window must be absorbed by the pending timer,
	// not re-arm it.
	before := m.pushTimer
	m.pulse()
	if m.pushTimer != before {
		t.Fatal("a frame inside the window replaced the pending timer (re-arming debounce)")
	}
	m.stopWatch()
}

// TestPulseSurvivesNilWatchCtx checks a directly constructed Manager without a
// watcher context.
func TestPulseSurvivesNilWatchCtx(t *testing.T) {
	m := &Manager{}
	if m.watchDone() {
		t.Fatal("a Manager with no watchCtx must not report itself shut down")
	}
	m.pulse()
	m.watchMu.Lock()
	if m.pushTimer != nil {
		m.pushTimer.Stop()
		m.pushTimer = nil
	}
	m.watchMu.Unlock()
	m.stopWatch()
}

// TestRunWatchTerminatesChildOnParseError uses a child that remains idle after
// invalid output. Waiting without killing it would prevent supervision from
// retrying.
func TestRunWatchTerminatesChildOnParseError(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	writeFile(t, statusPath, statusFixture)

	stub := filepath.Join(dir, "tailscale")
	writeStub(t, stub, statusPath,
		"  printf 'Connected.\\n'\n"+
			"  printf '{\\n\\t\"State\": 6\\n}\\n'\n"+
			"  printf 'this is not json\\n'\n"+
			"  while :; do sleep 1; done\n")

	m := newWatchManager(t, server.New(0, nil), stub)

	done := make(chan error, 1)
	go func() { done <- m.runWatch(m.watchCtx) }()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("runWatch returned nil for a stream it could not parse")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("runWatch blocked on a live child after a parse error")
	}
}

// TestRunWatchFoldsChildStderrIntoError checks that the returned error includes
// the child diagnostic.
func TestRunWatchFoldsChildStderrIntoError(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	writeFile(t, statusPath, statusFixture)

	stub := filepath.Join(dir, "tailscale")
	writeStub(t, stub, statusPath,
		"  printf 'flag provided but not defined: -bogus\\n' >&2\n"+
			"  exit 2\n")

	m := newWatchManager(t, server.New(0, nil), stub)

	done := make(chan error, 1)
	go func() { done <- m.runWatch(m.watchCtx) }()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("runWatch returned nil for a child that exited non-zero")
		}
		if !strings.Contains(err.Error(), "flag provided but not defined: -bogus") {
			t.Fatalf("runWatch error %q does not contain the child's stderr", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("runWatch blocked on a child that already exited")
	}
}

// TestRunWatchCapsStderr checks that oversized stderr produces a bounded error
// with a truncation marker.
func TestRunWatchCapsStderr(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	writeFile(t, statusPath, statusFixture)

	written := watchStderrCap * 2
	stub := filepath.Join(dir, "tailscale")
	writeStub(t, stub, statusPath,
		"  head -c "+strconv.Itoa(written)+" /dev/zero | tr '\\0' 'x' >&2\n"+
			"  exit 2\n")

	m := newWatchManager(t, server.New(0, nil), stub)

	done := make(chan error, 1)
	go func() { done <- m.runWatch(m.watchCtx) }()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("runWatch returned nil for a child that exited non-zero")
		}
		msg := err.Error()
		if len(msg) > watchStderrCap+128 {
			t.Fatalf("runWatch error is %d bytes for a %d-byte write; stderr capture is not bounded", len(msg), written)
		}
		if !strings.Contains(msg, "truncated") {
			t.Fatalf("runWatch error %q lacks a truncation marker for an over-cap write", msg)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("runWatch blocked on a child that already exited")
	}
}

// TestRunWatchInvokesWatchIpnWithNoFlags checks the exact argument list.
// Unsupported flags would cause watcher startup to fail repeatedly.
func TestRunWatchInvokesWatchIpnWithNoFlags(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	writeFile(t, statusPath, statusFixture)
	argsPath := filepath.Join(dir, "args.log")

	stub := filepath.Join(dir, "tailscale")
	writeFile(t, stub, "#!/bin/sh\n"+
		"if [ \"$1\" = status ]; then cat "+shellQuote(statusPath)+"; exit 0; fi\n"+
		"if [ \"$1\" = debug ] && [ \"$2\" = prefs ]; then printf '{}\\n'; exit 0; fi\n"+
		"if [ \"$1\" = debug ] && [ \"$2\" = watch-ipn ]; then\n"+
		"  echo \"$*\" > "+shellQuote(argsPath)+"\n"+
		"  printf 'Connected.\\n'\n"+
		"  while :; do sleep 1; done\n"+
		"fi\n"+
		"exit 0\n")
	if err := os.Chmod(stub, 0o755); err != nil {
		t.Fatal(err)
	}

	m := newWatchManager(t, server.New(0, nil), stub)
	m.startWatch()

	waitFor(t, 5*time.Second, "watcher child to record its argv", func() bool {
		_, err := os.Stat(argsPath)
		return err == nil
	})

	raw, err := os.ReadFile(argsPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(raw)); got != "debug watch-ipn" {
		t.Fatalf("watch-ipn invoked with argv %q, want exactly %q — an unsupported flag was reintroduced", got, "debug watch-ipn")
	}
}

func TestReadFramesRejectsGarbage(t *testing.T) {
	m := &Manager{}
	m.watchCtx, m.watchStop = context.WithCancel(context.Background())
	t.Cleanup(m.watchStop)
	// Skipping banners must consume input. A stream without a JSON value must end
	// with an error.
	err := m.readFrames(strings.NewReader("Connected.\n{\"State\": 6}\nnot json at all\n"), func() {})
	if err == nil {
		t.Fatal("readFrames accepted a malformed stream")
	}
}

// TestWatcherBroadcastReachesSubscriber checks that a bus event updates a
// subscriber without a client request or VGS write action.
func TestWatcherBroadcastReachesSubscriber(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	triggerPath := filepath.Join(dir, "trigger")
	writeFile(t, statusPath, stoppedStatusFixture)

	stub := filepath.Join(dir, "tailscale")
	writeStub(t, stub, statusPath,
		"  printf 'Connected.\\n'\n"+
			"  while [ ! -f "+shellQuote(triggerPath)+" ]; do sleep 0.05; done\n"+
			"  printf '{\\n\\t\"State\": 6\\n}\\n'\n"+
			"  while :; do sleep 1; done\n")

	srv, sock := startTestServer(t)
	m := newWatchManager(t, srv, stub)
	m.startWatch()

	c, sc := subscribeTailscale(t, sock)

	// The initial snapshot precedes the daemon state change.
	snapshot := readEvent(t, c, sc, "tailscale")
	if snapshot["backendState"] != "NoState" || snapshot["connected"] != false {
		t.Fatalf("subscribe snapshot = %v, want NoState/false", snapshot)
	}

	writeFile(t, statusPath, statusFixture)
	writeFile(t, triggerPath, "go")

	update := readEvent(t, c, sc, "tailscale")
	if update["backendState"] != "Running" || update["connected"] != true {
		t.Fatalf("pushed state = %v, want Running/true", update)
	}
	// The shell picks its re-fetch cadence from this, not from the capability.
	if update["watcherActive"] != true {
		t.Fatalf("pushed state watcherActive = %v, want true", update["watcherActive"])
	}
}

// TestWatcherActiveClearsDuringRestartBackoff reads WatcherActive while no child
// can deliver events. A replacement child must restore the flag.
func TestWatcherActiveClearsDuringRestartBackoff(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	writeFile(t, statusPath, statusFixture)

	// The child stays alive long enough to observe its running state, then exits to
	// trigger backoff.
	stub := filepath.Join(dir, "tailscale")
	writeStub(t, stub, statusPath,
		"  printf 'Connected.\\n'\n"+
			"  printf '{\\n\\t\"State\": 6\\n}\\n'\n"+
			"  sleep 0.6\n"+
			"  exit 0\n")

	m := newWatchManager(t, server.New(0, nil), stub)
	m.startWatch()

	waitFor(t, 5*time.Second, "first watcher child to start", func() bool {
		return m.watchAlive.Load()
	})

	// Read status after the child exits and before the replacement starts.
	waitFor(t, 5*time.Second, "watcher child to exit", func() bool {
		return !m.watchAlive.Load()
	})
	state, err := m.status()
	if err != nil {
		t.Fatal(err)
	}
	if state.WatcherActive {
		t.Fatal("WatcherActive is true during the restart backoff, when no child exists to push")
	}

	// Proof this was a backoff gap and not the give-up path: a replacement
	// starts, and the flag comes back with it.
	waitFor(t, 10*time.Second, "replacement watcher child to start", func() bool {
		return m.watchAlive.Load()
	})
	state, err = m.status()
	if err != nil {
		t.Fatal(err)
	}
	if !state.WatcherActive {
		t.Fatal("WatcherActive stayed false after a replacement child started")
	}
}

// TestStatusReadsDoNotOverlap checks that a watcher read holds its slot through
// broadcast. Overlapping reads could complete out of order and publish stale
// state.
func TestStatusReadsDoNotOverlap(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	writeFile(t, statusPath, statusFixture)
	marks := filepath.Join(dir, "marks.log")

	// The status stub takes longer than the scheduling floor. A shorter read could
	// not expose overlap because the floor alone would serialize it.
	stub := filepath.Join(dir, "tailscale")
	writeFile(t, stub, "#!/bin/sh\n"+
		"if [ \"$1\" = status ]; then\n"+
		"  printf 'S\\n' >> "+shellQuote(marks)+"\n"+
		"  sleep 2.5\n"+
		"  cat "+shellQuote(statusPath)+"\n"+
		"  printf 'E\\n' >> "+shellQuote(marks)+"\n"+
		"  exit 0\n"+
		"fi\n"+
		"if [ \"$1\" = debug ] && [ \"$2\" = prefs ]; then printf '{}\\n'; exit 0; fi\n"+
		"if [ \"$1\" = debug ] && [ \"$2\" = watch-ipn ]; then\n"+
		"  printf 'Connected.\\n'\n"+
		"  while :; do printf '{\\n\\t\"State\": 6\\n}\\n'; sleep 0.05; done\n"+
		"fi\n"+
		"exit 0\n")
	if err := os.Chmod(stub, 0o755); err != nil {
		t.Fatal(err)
	}

	m := newWatchManager(t, server.New(0, nil), stub)
	m.startWatch()
	time.Sleep(9 * time.Second)
	m.stopWatch()
	time.Sleep(3 * time.Second)

	raw, err := os.ReadFile(marks)
	if err != nil {
		t.Fatalf("no status read happened at all: %v", err)
	}
	depth, maxDepth, reads := 0, 0, 0
	for _, line := range strings.Fields(string(raw)) {
		switch line {
		case "S":
			depth++
			reads++
			if depth > maxDepth {
				maxDepth = depth
			}
		case "E":
			depth--
		}
	}
	if reads < 2 {
		t.Fatalf("only %d status reads in 9s of continuous frames; the test proved nothing", reads)
	}
	if maxDepth > 1 {
		t.Fatalf("%d concurrent status reads (of %d); completion order can then reorder broadcasts", maxDepth, reads)
	}
}

// TestWatcherGivingUpClearsWatcherActive: once supervision stops retrying, the
// backend must stop claiming to be watching, or the shell keeps the
// watcher-present cadence with no watcher behind it.
func TestWatcherGivingUpClearsWatcherActive(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	writeFile(t, statusPath, statusFixture)

	// The stub records failed startup attempts. Observe that attempts stop, because
	// an inactive flag alone also describes backoff.
	attempts := filepath.Join(dir, "attempts.log")
	stub := filepath.Join(dir, "tailscale")
	writeStub(t, stub, statusPath,
		"  printf 'x\\n' >> "+shellQuote(attempts)+"\n"+
			"  printf 'unknown subcommand\\n' >&2\n"+
			"  exit 1\n")

	m := newWatchManager(t, server.New(0, nil), stub)
	m.startWatch()

	countAttempts := func() int {
		raw, err := os.ReadFile(attempts)
		if err != nil {
			return 0
		}
		return len(strings.Fields(string(raw)))
	}

	waitFor(t, 30*time.Second, "supervision to exhaust its retries", func() bool {
		return countAttempts() >= watchMaxFastFailures
	})

	state, err := m.status()
	if err != nil {
		t.Fatal(err)
	}
	if state.WatcherActive {
		t.Fatal("watcherActive is true after supervision gave up")
	}
	// Terminal, not merely another backoff gap: no further attempts, and the
	// flag does not come back.
	settled := countAttempts()
	time.Sleep(3 * time.Second)
	if now := countAttempts(); now != settled {
		t.Fatalf("supervision is still retrying (%d -> %d attempts); this was a backoff gap, not give-up", settled, now)
	}
	again, err := m.status()
	if err != nil {
		t.Fatal(err)
	}
	if again.WatcherActive {
		t.Fatal("watcherActive went back to true after giving up")
	}
}
