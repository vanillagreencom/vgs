package server

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"vshell/backend/internal/protocol"
)

// startTestServer spins the daemon on a temp unix socket and returns a dial
// helper. The uid is our own so the peer-credential check passes.
func startTestServer(t *testing.T) func(t *testing.T) *testConn {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "t.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	srv := New(uint32(ourUID(t)), nil)
	go srv.Serve(ln)

	return func(t *testing.T) *testConn {
		t.Helper()
		c, err := net.DialTimeout("unix", sock, 2*time.Second)
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		t.Cleanup(func() { c.Close() })
		return &testConn{c: c, sc: bufio.NewScanner(c)}
	}
}

type testConn struct {
	c  net.Conn
	sc *bufio.Scanner
}

func (tc *testConn) send(t *testing.T, method string, params any) {
	t.Helper()
	req := protocol.Request{ID: json.RawMessage("7"), Method: method}
	if params != nil {
		p, _ := json.Marshal(params)
		req.Params = p
	}
	b, _ := json.Marshal(req)
	if _, err := tc.c.Write(append(b, '\n')); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func (tc *testConn) read(t *testing.T) protocol.Response {
	t.Helper()
	_ = tc.c.SetReadDeadline(time.Now().Add(2 * time.Second))
	if !tc.sc.Scan() {
		t.Fatalf("read: %v", tc.sc.Err())
	}
	var resp protocol.Response
	if err := json.Unmarshal(tc.sc.Bytes(), &resp); err != nil {
		t.Fatalf("decode %q: %v", tc.sc.Text(), err)
	}
	return resp
}

func TestPing(t *testing.T) {
	dial := startTestServer(t)
	tc := dial(t)
	tc.send(t, "ping", nil)
	resp := tc.read(t)
	if resp.Error != "" {
		t.Fatalf("ping error: %s", resp.Error)
	}
	m, ok := resp.Result.(map[string]any)
	if !ok || m["pong"] != true {
		t.Fatalf("ping result = %v, want {pong:true}", resp.Result)
	}
}

func TestGetServerInfo(t *testing.T) {
	dial := startTestServer(t)
	tc := dial(t)
	tc.send(t, "getServerInfo", nil)
	resp := tc.read(t)
	if resp.Error != "" {
		t.Fatalf("getServerInfo error: %s", resp.Error)
	}
	m := resp.Result.(map[string]any)
	if !contains(toStrings(m["capabilities"]), "core") {
		t.Fatalf("capabilities missing 'core': %v", m["capabilities"])
	}
	for _, want := range []string{"ping", "getServerInfo", "subscribe"} {
		if !contains(toStrings(m["methods"]), want) {
			t.Fatalf("methods missing %q: %v", want, m["methods"])
		}
	}
	if m["vgsApiVersion"].(float64) != 1 {
		t.Fatalf("vgsApiVersion = %v, want 1", m["vgsApiVersion"])
	}
}

func TestUnknownMethod(t *testing.T) {
	dial := startTestServer(t)
	tc := dial(t)
	tc.send(t, "network.getState", nil)
	resp := tc.read(t)
	if resp.Error == "" {
		t.Fatal("expected error for unimplemented method")
	}
}

func TestSubscribeSendsServerFrameAndToleratesUnknown(t *testing.T) {
	dial := startTestServer(t)
	tc := dial(t)
	// Mix of never-implemented service names must not error the subscription.
	tc.send(t, "subscribe", map[string]any{"services": []string{"network", "theme.auto", "bogus"}})
	resp := tc.read(t)
	if resp.Error != "" {
		t.Fatalf("subscribe error: %s", resp.Error)
	}
	ev := resp.Result.(map[string]any)
	if ev["service"] != "server" {
		t.Fatalf("first event service = %v, want 'server'", ev["service"])
	}
	data := ev["data"].(map[string]any)
	if !contains(toStrings(data["capabilities"]), "core") {
		t.Fatalf("server frame missing core capability: %v", data)
	}
}

func TestBroadcastReachesSubscriber(t *testing.T) {
	sock := filepath.Join(t.TempDir(), "b.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	srv := New(uint32(ourUID(t)), nil)
	go srv.Serve(ln)

	c, err := net.DialTimeout("unix", sock, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	tc := &testConn{c: c, sc: bufio.NewScanner(c)}
	tc.send(t, "subscribe", map[string]any{"services": []string{"evdev"}})
	_ = tc.read(t) // server frame

	// Give the server a moment to register the subscriber, then broadcast.
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		srv.mu.RLock()
		n := len(srv.subscribers)
		srv.mu.RUnlock()
		if n > 0 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	srv.Broadcast("evdev", map[string]any{"capsLock": true})
	resp := tc.read(t)
	ev := resp.Result.(map[string]any)
	if ev["service"] != "evdev" {
		t.Fatalf("broadcast service = %v, want evdev", ev["service"])
	}
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

func toStrings(v any) []string {
	arr, _ := v.([]any)
	out := make([]string, 0, len(arr))
	for _, e := range arr {
		if s, ok := e.(string); ok {
			out = append(out, s)
		}
	}
	return out
}

func ourUID(t *testing.T) int {
	t.Helper()
	return os.Getuid()
}
