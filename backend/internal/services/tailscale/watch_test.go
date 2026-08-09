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
	writeFile(t, stub, "#!/bin/sh\n"+
		"if [ \"$1\" = status ]; then cat "+shellQuote(statusPath)+"; exit 0; fi\n"+
		"if [ \"$1\" = debug ] && [ \"$2\" = prefs ]; then printf '{}\\n'; exit 0; fi\n"+
		"if [ \"$1\" = debug ] && [ \"$2\" = watch-ipn ]; then\n"+
		"  printf 'Connected.\\n'\n"+
		"  while [ ! -f "+shellQuote(triggerPath)+" ]; do sleep 0.05; done\n"+
		"  printf '{\\n\\t\"State\": 6\\n}\\n'\n"+
		"  while :; do sleep 1; done\n"+
		"fi\n"+
		"exit 0\n")
	if err := os.Chmod(stub, 0o755); err != nil {
		t.Fatal(err)
	}

	sock := filepath.Join(dir, "t.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	srv := server.New(uint32(os.Getuid()), nil)

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
	go srv.Serve(ln)
	m.startWatch()

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

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}
