package tailscale

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"vshell/backend/internal/server"
)

// Frames as tailscale emits them: pretty-printed, concatenated, no separators,
// after a human banner line on some builds. The Prefs blob is included verbatim
// (with a placeholder private key) so the decoder is exercised on the real
// shape — nothing from it may ever reach a log or a broadcast.
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

// TestPulseIsNotStarvedBySustainedTraffic is the assertion that would have
// caught the trailing-edge debounce: with a re-arming timer, a frame stream
// faster than the coalescing window postpones every push for as long as the
// traffic lasts — which is precisely what a netmap burst looks like.
func TestPulseIsNotStarvedBySustainedTraffic(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	writeFile(t, statusPath, statusFixture)

	// A watcher that never stops talking: one frame every 50ms, forever, which
	// is eight times faster than the 400ms window.
	stub := filepath.Join(dir, "tailscale")
	writeStub(t, stub, statusPath,
		"  printf 'Connected.\\n'\n"+
			"  while :; do printf '{\\n\\t\"State\": 6\\n}\\n'; sleep 0.05; done\n")

	srv, sock := startTestServer(t)
	m := newWatchManager(t, srv, stub)
	m.startWatch()

	c, sc := subscribeTailscale(t, sock)
	_ = readEvent(t, c, sc, "tailscale") // subscribe snapshot

	// The ceiling is the delay computed for the first unserved frame, i.e. at
	// most watchMinInterval. Anything under a few seconds proves the push is
	// not being postponed by the ongoing stream.
	start := time.Now()
	update := readEvent(t, c, sc, "tailscale")
	elapsed := time.Since(start)
	if elapsed > 3*time.Second {
		t.Fatalf("first push under sustained traffic took %v, want <= 3s", elapsed)
	}
	if update["backendState"] != "Running" {
		t.Fatalf("pushed state = %v, want Running", update)
	}

	// ...and it keeps pushing rather than pushing once and starving after.
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

	// A push "just happened", so the floor has almost all of its time left.
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

// TestPulseSurvivesNilWatchCtx: a Manager built directly, as every other test
// in this package does, must not nil-panic when the watcher paths run.
func TestPulseSurvivesNilWatchCtx(t *testing.T) {
	m := &Manager{}
	if m.watchDone() {
		t.Fatal("a Manager with no watchCtx must not report itself shut down")
	}
	m.pulse() // must not panic
	m.watchMu.Lock()
	if m.pushTimer != nil {
		m.pushTimer.Stop()
		m.pushTimer = nil
	}
	m.watchMu.Unlock()
	m.stopWatch() // must not panic either
}

// TestRunWatchTerminatesChildOnParseError: the child stays alive and idle after
// emitting output the reader rejects. Without killing it, cmd.Wait blocks
// forever and supervision never restarts, never counts the failure, and never
// reaches its give-up limit.
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

// TestRunWatchInvokesWatchIpnWithNoFlags is the regression control for
// VGS-202: tailscale 1.102.2 rejects `--netmap=true` on `debug watch-ipn`
// ("flag provided but not defined: -netmap") because the flag was removed
// upstream, and every watcher restart burned the whole retry budget within
// seconds as a result. The stub records the exact argv it was invoked with so
// a future reintroduction of that flag, or any other, fails here rather than
// silently reproducing the outage.
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
	// The whole point of the banner skip is that it advances by lines to the
	// first JSON value; a stream that never contains one must error, not spin.
	err := m.readFrames(strings.NewReader("Connected.\n{\"State\": 6}\nnot json at all\n"), func() {})
	if err == nil {
		t.Fatal("readFrames accepted a malformed stream")
	}
}

// TestWatcherBroadcastReachesSubscriber is the end-to-end assertion for VGS-63:
// a subscriber that took its snapshot while tailscaled was still coming up
// receives an updated state when the ipn bus reports a transition, with no
// request of its own and no VGS-initiated write action.
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

	// The snapshot the shell would take on a cold boot: truthful, and wrong
	// within minutes.
	snapshot := readEvent(t, c, sc, "tailscale")
	if snapshot["backendState"] != "NoState" || snapshot["connected"] != false {
		t.Fatalf("subscribe snapshot = %v, want NoState/false", snapshot)
	}

	// tailscaled finishes coming up. Nothing in VGS asked for this.
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

// TestWatcherActiveClearsDuringRestartBackoff reads WatcherActive *during* the
// supervisor's backoff, not after give-up. Setting the flag when a child starts
// and never clearing it when that child exits left every status read in the gap
// claiming a watcher, so the shell held its five-minute watched cadence while
// nothing could deliver a push.
func TestWatcherActiveClearsDuringRestartBackoff(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	writeFile(t, statusPath, statusFixture)

	// A child that starts cleanly, emits one frame, stays up long enough to be
	// observed running, then exits — so supervision restarts it after a backoff
	// rather than giving up.
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

	// The child exits at once. Everything from here until the replacement
	// starts is backoff, and the first backoff is one second — plenty of room
	// to catch a status read inside it.
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

// TestStatusReadsDoNotOverlap: two `tailscale status` calls in the air at once
// broadcast in completion order, so an older read can land after a newer one
// and walk the shell's state backwards. The watcher must hold its slot until
// the read it started has been broadcast.
func TestStatusReadsDoNotOverlap(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	writeFile(t, statusPath, statusFixture)
	marks := filepath.Join(dir, "marks.log")

	// `status` brackets itself in the marker log and takes 2.5s — deliberately
	// LONGER than the 2s scheduling floor, which is the condition the finding
	// names ("each command may take up to 12s while the floor is 2s"). With a
	// read shorter than the floor the floor alone serialises them and the test
	// proves nothing; only a read that outlives it can overlap.
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
	time.Sleep(9 * time.Second) // several floor intervals of continuous frames
	m.stopWatch()
	time.Sleep(3 * time.Second) // let any read already running finish

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

	// A tailscale build with no `debug watch-ipn`: the subcommand exits at once,
	// every time. Each attempt records itself, so "gave up" is observed as
	// attempts stopping rather than inferred from a flag that also happens to
	// be false before the first child ever starts.
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

	// watchMaxFastFailures attempts, with backoff 1,2,4,8s between them.
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
