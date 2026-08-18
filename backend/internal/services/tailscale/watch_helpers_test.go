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
	"testing"
	"time"

	"vshell/backend/internal/protocol"
	"vshell/backend/internal/server"
)

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

// sunPathMax is the size of sockaddr_un.sun_path on Linux, including the
// terminating NUL — so a usable path is at most sunPathMax-1 bytes.
const sunPathMax = 108

// shortSocketPath returns a unix socket path guaranteed to fit in sun_path.
// t.TempDir() embeds the test name, which for the longer names in this file
// already runs to ~60 bytes before TMPDIR is taken into account; a long TMPDIR
// pushes it over and the listen fails with "invalid argument". Truncating would
// silently collide between tests, so an unusable path is a clear failure
// instead.
func shortSocketPath(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "vgs")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	sock := filepath.Join(dir, "t.sock")
	if len(sock) >= sunPathMax {
		t.Fatalf("socket path %q is %d bytes, at or over the %d-byte sun_path limit; "+
			"point TMPDIR at a shorter directory", sock, len(sock), sunPathMax)
	}
	return sock
}

// startTestServer listens on a short unix socket path and serves srv.
func startTestServer(t *testing.T) (*server.Server, string) {
	t.Helper()
	sock := shortSocketPath(t)
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

// waitFor polls until cond holds, failing with what it was waiting for.
func waitFor(t *testing.T, limit time.Duration, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(limit)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out after %v waiting for %s", limit, what)
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
