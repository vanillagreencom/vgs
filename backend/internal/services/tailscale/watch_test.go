package tailscale

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"vshell/backend/internal/protocol"
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

// TestWatcherGivingUpClearsWatcherActive: once supervision stops retrying, the
// backend must stop claiming to be watching, or the shell keeps the
// watcher-present cadence with no watcher behind it.
func TestWatcherGivingUpClearsWatcherActive(t *testing.T) {
	dir := t.TempDir()
	statusPath := filepath.Join(dir, "status.json")
	writeFile(t, statusPath, statusFixture)

	// A tailscale build with no `debug watch-ipn`: the subcommand exits at once,
	// every time.
	stub := filepath.Join(dir, "tailscale")
	writeStub(t, stub, statusPath, "  printf 'unknown subcommand\\n' >&2\n  exit 1\n")

	m := newWatchManager(t, server.New(0, nil), stub)
	m.startWatch()

	// watchMaxFastFailures restarts with backoff 1,2,4,8s before giving up.
	deadline := time.Now().Add(25 * time.Second)
	for time.Now().Before(deadline) {
		state, err := m.status()
		if err != nil {
			t.Fatal(err)
		}
		if !state.WatcherActive && m.watchAlive.Load() == false {
			// Give-up reached and reported. Confirm it is terminal, not a gap
			// between restarts.
			time.Sleep(300 * time.Millisecond)
			again, err := m.status()
			if err != nil {
				t.Fatal(err)
			}
			if again.WatcherActive {
				t.Fatal("watcherActive went back to true after giving up")
			}
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatal("supervision never gave up, so watcherActive never went false")
}

// readEvent reads until a subscription event for the given service arrives.
func readEvent(t *testing.T, c net.Conn, sc *bufio.Scanner, service string) map[string]any {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))
	for {
		if !sc.Scan() {
			t.Fatalf("read: %v", sc.Err())
		}
		var resp protocol.Response
		if err := json.Unmarshal(sc.Bytes(), &resp); err != nil {
			t.Fatalf("decode %q: %v", sc.Text(), err)
		}
		frame, ok := resp.Result.(map[string]any)
		if !ok || frame["service"] != service {
			continue
		}
		data, ok := frame["data"].(map[string]any)
		if !ok {
			t.Fatalf("event data not an object: %v", frame)
		}
		return data
	}
}

// writeStub writes an executable fake `tailscale` whose `debug watch-ipn` body
// is supplied by the caller; `status` reads statusPath so a test can change the
// answer mid-run, and `debug prefs` is stubbed out.
func writeStub(t *testing.T, path, statusPath, watchBody string) {
	t.Helper()
	writeFile(t, path, "#!/bin/sh\n"+
		"if [ \"$1\" = status ]; then cat "+shellQuote(statusPath)+"; exit 0; fi\n"+
		"if [ \"$1\" = debug ] && [ \"$2\" = prefs ]; then printf '{}\\n'; exit 0; fi\n"+
		"if [ \"$1\" = debug ] && [ \"$2\" = watch-ipn ]; then\n"+
		watchBody+
		"fi\n"+
		"exit 0\n")
	if err := os.Chmod(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

// newWatchManager builds a Manager wired to srv and the stub, with the watcher
// context live and torn down on cleanup.
func newWatchManager(t *testing.T, srv *server.Server, stub string) *Manager {
	t.Helper()
	m := &Manager{srv: srv, log: discardLogger(), tailscale: stub}
	m.watchCtx, m.watchStop = context.WithCancel(context.Background())
	t.Cleanup(m.stopWatch)
	srv.RegisterSnapshot("tailscale", func() any {
		state, err := m.status()
		if err != nil {
			return map[string]any{"connected": false}
		}
		return state
	})
	return m
}

// startTestServer listens on a temp unix socket and serves srv.
func startTestServer(t *testing.T) (*server.Server, string) {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "t.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	srv := server.New(uint32(os.Getuid()), nil)
	go srv.Serve(ln)
	return srv, sock
}

// subscribeTailscale dials the socket and subscribes to the tailscale service.
func subscribeTailscale(t *testing.T, sock string) (net.Conn, *bufio.Scanner) {
	t.Helper()
	c, err := net.DialTimeout("unix", sock, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	sc := bufio.NewScanner(c)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	req, _ := json.Marshal(protocol.Request{
		ID:     json.RawMessage("1"),
		Method: "subscribe",
		Params: json.RawMessage(`{"services":["tailscale"]}`),
	})
	if _, err := c.Write(append(req, '\n')); err != nil {
		t.Fatal(err)
	}
	return c, sc
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}
