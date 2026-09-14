package server

import (
	"bufio"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"vshell/backend/internal/protocol"
)

// discardLogger keeps expected warnings (queue overflow, rejected calls) out of
// test output without hiding them from the code under test.
func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// startTestServer spins the daemon on a temp unix socket and returns the server
// plus a dial helper. The uid is our own so the peer-credential check passes.
// Handlers and snapshots must be registered on the returned server before the
// first dial.
func startTestServer(t *testing.T) (*Server, func(t *testing.T) *testConn) {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "t.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	srv := New(uint32(ourUID(t)), discardLogger())
	go srv.Serve(ln)

	return srv, func(t *testing.T) *testConn {
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
	tc.sendID(t, "7", method, params)
}

func (tc *testConn) sendID(t *testing.T, id, method string, params any) {
	t.Helper()
	req := protocol.Request{ID: json.RawMessage(id), Method: method}
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
	_, dial := startTestServer(t)
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
	_, dial := startTestServer(t)
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
	_, dial := startTestServer(t)
	tc := dial(t)
	tc.send(t, "network.getState", nil)
	resp := tc.read(t)
	if resp.Error == "" {
		t.Fatal("expected error for unimplemented method")
	}
}

func TestSubscribeSendsServerFrameAndToleratesUnknown(t *testing.T) {
	_, dial := startTestServer(t)
	tc := dial(t)
	// Unknown service names must not reject the subscription.
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
	srv, dial := startTestServer(t)
	tc := dial(t)
	tc.send(t, "subscribe", map[string]any{"services": []string{"evdev"}})
	_ = tc.read(t) // server frame
	awaitSubscriber(t, srv)

	srv.Broadcast("evdev", map[string]any{"capsLock": true})
	resp := tc.read(t)
	ev := resp.Result.(map[string]any)
	if ev["service"] != "evdev" {
		t.Fatalf("broadcast service = %v, want evdev", ev["service"])
	}
}

// TestConsecutiveBroadcastsBothArrive pins that a frame already handed to the
// writer stops being a coalescing target. If it stayed one, the second
// broadcast would overwrite a frame that was already sent and its state would
// never reach the subscriber.
func TestConsecutiveBroadcastsBothArrive(t *testing.T) {
	srv, dial := startTestServer(t)
	tc := dial(t)
	tc.send(t, "subscribe", map[string]any{"services": []string{"evdev"}})
	_ = tc.read(t) // server frame
	awaitSubscriber(t, srv)

	for _, want := range []bool{true, false, true} {
		srv.Broadcast("evdev", map[string]any{"capsLock": want})
		ev := tc.read(t).Result.(map[string]any)
		data := ev["data"].(map[string]any)
		if data["capsLock"] != want {
			t.Fatalf("broadcast delivered capsLock=%v, want %v", data["capsLock"], want)
		}
	}
}

func awaitSubscriber(t *testing.T, srv *Server) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		srv.mu.RLock()
		n := len(srv.subscribers)
		srv.mu.RUnlock()
		if n > 0 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("no subscriber registered within the deadline")
}

// eventFor reads frames until one carries service, so an unrelated snapshot
// cannot make the assertion depend on map iteration order.
func (tc *testConn) eventFor(t *testing.T, service string) any {
	t.Helper()
	for i := 0; i < 8; i++ {
		resp := tc.read(t)
		ev, ok := resp.Result.(map[string]any)
		if !ok {
			t.Fatalf("frame result is %T, want an event", resp.Result)
		}
		if ev["service"] == service {
			return ev["data"]
		}
	}
	t.Fatalf("no %q event within 8 frames", service)
	return nil
}

func TestSubscribeReadsCachedStateAndKicksRefresh(t *testing.T) {
	srv, dial := startTestServer(t)
	kicked := make(chan struct{}, 1)
	srv.RegisterSnapshot("network", func() any { return "cached" })
	srv.RegisterSnapshotRefresh("network", func() { kicked <- struct{}{} })

	tc := dial(t)
	tc.send(t, "subscribe", map[string]any{"services": []string{"network"}})
	if got := tc.eventFor(t, "network"); got != "cached" {
		t.Fatalf("snapshot data = %v, want the service's cached state", got)
	}
	select {
	case <-kicked:
	case <-time.After(2 * time.Second):
		t.Fatal("subscribe did not kick the service refresh; live state would never follow the cached snapshot")
	}
}

// A service with nothing read yet sends no frame at all. An empty state would
// reach the shell as fact and blank a list the kicked refresh is about to fill.
func TestSnapshotWithNoStateYetSendsNoFrame(t *testing.T) {
	srv, dial := startTestServer(t)
	srv.RegisterSnapshot("network", func() any { return nil })
	srv.RegisterSnapshot("cups", func() any { return "cups-state" })

	tc := dial(t)
	tc.send(t, "subscribe", map[string]any{"services": []string{"network", "cups"}})
	if ev := tc.read(t).Result.(map[string]any); ev["service"] != "server" {
		t.Fatalf("first frame service = %v, want server", ev["service"])
	}
	if ev := tc.read(t).Result.(map[string]any); ev["service"] != "cups" {
		t.Fatalf("second frame service = %v, want cups: the network snapshot had no state to send", ev["service"])
	}

	// Nothing from network is queued behind it: the next frame is a broadcast.
	awaitSubscriber(t, srv)
	srv.Broadcast("cups", "later")
	ev := tc.read(t).Result.(map[string]any)
	if ev["service"] != "cups" || ev["data"] != "later" {
		t.Fatalf("next frame = %v, want the cups broadcast rather than an empty network snapshot", ev)
	}
}

// subscribeIdleConn registers a conn whose writer is not running, so a test can
// read what Broadcast left for a peer that has not drained the socket.
func subscribeIdleConn(t *testing.T, srv *Server, services ...string) *conn {
	t.Helper()
	c := newIdleConn(t)
	set := subscription{}
	for _, service := range services {
		set[service] = true
	}
	srv.mu.Lock()
	srv.subscribers[c] = set
	srv.mu.Unlock()
	return c
}

// TestBroadcastKeepsEveryFrameForAnUndeclaredService pins the default. A
// service that broadcasts distinct events under one name — mimeapps sends one
// browser.open_requested per URL, dbusbridge one dbus frame per subscription id
// — loses the earlier event outright if its frames coalesce.
func TestBroadcastKeepsEveryFrameForAnUndeclaredService(t *testing.T) {
	srv, _ := startTestServer(t)
	c := subscribeIdleConn(t, srv, "browser.open_requested")

	srv.Broadcast("browser.open_requested", "https://one.example")
	srv.Broadcast("browser.open_requested", "https://two.example")

	got := queuedEvents(t, c)
	if len(got) != 2 {
		t.Fatalf("queued %d frames, want both: a link the user opened must not be dropped silently: %v", len(got), got)
	}
	if got[0][1] != "https://one.example" || got[1][1] != "https://two.example" {
		t.Fatalf("queued payloads = %v, want both requests in order", got)
	}
}

func TestBroadcastCoalescesADeclaredService(t *testing.T) {
	srv, _ := startTestServer(t)
	srv.CoalesceBroadcasts("network")
	c := subscribeIdleConn(t, srv, "network")

	srv.Broadcast("network", "stale")
	srv.Broadcast("network", "fresh")

	got := queuedEvents(t, c)
	if len(got) != 1 {
		t.Fatalf("queued %d frames, want 1 for whole-state broadcasts: %v", len(got), got)
	}
	if got[0][1] != "fresh" {
		t.Fatalf("queued payload = %v, want the newest state", got[0][1])
	}
}

// A subscriber to "all", and one that names no service, are both shapes the
// shell sends. Either arm of the subscription test could be dropped without a
// named-service test noticing.
func TestWildcardSubs(t *testing.T) {
	for _, tc := range []struct {
		name     string
		services []string
	}{
		{"all", []string{"all"}},
		{"bare", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, dial := startTestServer(t)
			conn := dial(t)
			var params any
			if tc.services != nil {
				params = map[string]any{"services": tc.services}
			}
			conn.send(t, "subscribe", params)
			_ = conn.read(t) // server frame
			awaitSubscriber(t, srv)

			srv.Broadcast("evdev", map[string]any{"capsLock": true})
			ev := conn.read(t).Result.(map[string]any)
			if ev["service"] != "evdev" {
				t.Fatalf("frame service = %v, want the unrelated service to still arrive", ev["service"])
			}
		})
	}
}

// A service whose first query failed holds no state and sends no snapshot. Its
// refresh is the only thing that can fill it, so every subscribe must kick it,
// not only the one that first covered the service.
func TestResubscribeKicksRefreshForAlreadyCoveredServices(t *testing.T) {
	srv, dial := startTestServer(t)
	kicks := make(chan struct{}, 4)
	srv.RegisterSnapshot("network", func() any { return nil })
	srv.RegisterSnapshotRefresh("network", func() { kicks <- struct{}{} })

	tc := dial(t)
	tc.send(t, "subscribe", map[string]any{"services": []string{"network"}})
	_ = tc.read(t) // server frame
	awaitKick(t, kicks, "the first subscribe")

	tc.send(t, "subscribe", map[string]any{"services": []string{"network"}})
	_ = tc.read(t) // server frame
	awaitKick(t, kicks, "a repeat subscribe covering the same service")
}

// A warm service the subscription did not change needs no query. Every popout
// open and close re-sends the whole set, and re-running those queries is the
// cost this contract exists to remove.
func TestResubscribeDoesNotRequeryAWarmService(t *testing.T) {
	srv, dial := startTestServer(t)
	kicks := make(chan struct{}, 8)
	srv.RegisterSnapshot("network", func() any { return "warm" })
	srv.RegisterSnapshotRefresh("network", func() { kicks <- struct{}{} })

	tc := dial(t)
	tc.send(t, "subscribe", map[string]any{"services": []string{"network"}})
	if got := tc.eventFor(t, "network"); got != "warm" {
		t.Fatalf("first subscribe data = %v", got)
	}
	awaitKick(t, kicks, "the first subscribe")

	tc.send(t, "subscribe", map[string]any{"services": []string{"network"}})
	_ = tc.read(t) // server frame
	// A later broadcast proves the second subscribe was fully handled, so an
	// absent kick is a decision rather than a race with one still to come.
	awaitSubscriber(t, srv)
	srv.Broadcast("network", "later")
	if got := tc.eventFor(t, "network"); got != "later" {
		t.Fatalf("next frame = %v, want the broadcast", got)
	}
	select {
	case <-kicks:
		t.Fatal("a repeat subscribe re-ran the query for a service it already held warm")
	default:
	}
}

func awaitKick(t *testing.T, kicks <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-kicks:
	case <-time.After(2 * time.Second):
		t.Fatalf("no refresh kick followed %s; a service whose first query failed would stay empty for the life of the connection", what)
	}
}

func TestResubscribeSendsOnlyNewServices(t *testing.T) {
	srv, dial := startTestServer(t)
	srv.RegisterSnapshot("network", func() any { return "network-state" })
	srv.RegisterSnapshot("cups", func() any { return "cups-state" })

	tc := dial(t)
	tc.send(t, "subscribe", map[string]any{"services": []string{"network"}})
	if got := tc.eventFor(t, "network"); got != "network-state" {
		t.Fatalf("first subscribe network data = %v", got)
	}

	tc.send(t, "subscribe", map[string]any{"services": []string{"network", "cups"}})
	// The server frame precedes the snapshots of both subscribes.
	if ev := tc.read(t).Result.(map[string]any); ev["service"] != "server" {
		t.Fatalf("resubscribe first frame service = %v, want server", ev["service"])
	}
	ev := tc.read(t).Result.(map[string]any)
	if ev["service"] != "cups" {
		t.Fatalf("resubscribe sent %v; only the newly added service may be re-sent, or every popout open re-runs the shell's per-service setup", ev["service"])
	}

	// Nothing else is queued: a broadcast now arrives next.
	awaitSubscriber(t, srv)
	srv.Broadcast("network", "fresh")
	if got := tc.eventFor(t, "network"); got != "fresh" {
		t.Fatalf("next network frame = %v, want the broadcast, not a repeat snapshot", got)
	}
}

func TestSaturatedMethodRejectsAndLeavesOtherMethodsLive(t *testing.T) {
	srv, dial := startTestServer(t)
	release := make(chan struct{})
	srv.Register("slow", "slow.call", func(json.RawMessage) (any, error) {
		<-release
		return "done", nil
	})
	t.Cleanup(func() { close(release) })

	tc := dial(t)
	// One call occupies the worker and methodDepth more fill its queue; the
	// rest must be refused rather than back up into the read loop.
	for i := 0; i < methodDepth+8; i++ {
		tc.sendID(t, strconv.Itoa(100+i), "slow.call", nil)
	}

	// The read loop is still live: a different method answers while slow.call
	// is blocked.
	tc.sendID(t, "9", "ping", nil)

	busy := 0
	pong := false
	for i := 0; i < methodDepth+16 && !pong; i++ {
		resp := tc.read(t)
		switch {
		case resp.Error != "":
			if !strings.HasPrefix(resp.Error, "busy: ") {
				t.Fatalf("unexpected error frame: %s", resp.Error)
			}
			busy++
		case string(resp.ID) == "9":
			pong = true
		}
	}
	if busy == 0 {
		t.Fatal("a saturated method queue answered nothing; the caller would wait on a reply that never comes")
	}
	if !pong {
		t.Fatal("ping went unanswered while slow.call was saturated; a slider drag would stall the lock call on the same socket")
	}
}

// setterParams is the shape a keep-latest device setter is keyed on.
type setterParams struct {
	Device  string `json:"device"`
	Percent int    `json:"percent"`
}

func setterDeviceKey(params json.RawMessage) string {
	var p setterParams
	if err := json.Unmarshal(params, &p); err != nil {
		return ""
	}
	return p.Device
}

// blockingSetter registers a keep-latest method whose first call parks until
// the returned channel is closed, and records every call that reached it.
func blockingSetter(t *testing.T, srv *Server) (release chan struct{}, applied func() []setterParams) {
	t.Helper()
	release = make(chan struct{})
	var mu sync.Mutex
	var seen []setterParams
	srv.RegisterLatest("brightness", "brightness.setBrightness", func(params json.RawMessage) (any, error) {
		var p setterParams
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, err
		}
		mu.Lock()
		first := len(seen) == 0
		seen = append(seen, p)
		mu.Unlock()
		if first {
			<-release
		}
		return p, nil
	}, setterDeviceKey)
	return release, func() []setterParams {
		mu.Lock()
		defer mu.Unlock()
		return append([]setterParams(nil), seen...)
	}
}

func awaitHandlerEntered(t *testing.T, applied func() []setterParams) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(applied()) > 0 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("the handler never started; the later calls would not contend for a waiting slot")
}

func TestKeepLatestSupersedesWaitingCallForTheSameKey(t *testing.T) {
	srv, dial := startTestServer(t)
	release, applied := blockingSetter(t, srv)

	tc := dial(t)
	tc.sendID(t, "1", "brightness.setBrightness", map[string]any{"device": "eDP-1", "percent": 10})
	awaitHandlerEntered(t, applied)
	tc.sendID(t, "2", "brightness.setBrightness", map[string]any{"device": "eDP-1", "percent": 50})
	tc.sendID(t, "3", "brightness.setBrightness", map[string]any{"device": "eDP-1", "percent": 90})

	superseded := tc.read(t)
	if string(superseded.ID) != "2" {
		t.Fatalf("superseded reply id = %s, want the replaced call 2", superseded.ID)
	}
	// A superseded call is not a failure. Shipped clients toast an error frame,
	// clear the device's state and rescan, so the reply must read as a success.
	if superseded.Error != "" {
		t.Fatalf("replaced call answered with error %q; supersession is not a failure", superseded.Error)
	}
	result, ok := superseded.Result.(map[string]any)
	if !ok || result["superseded"] != true {
		t.Fatalf("replaced call result = %v, want a success marked superseded", superseded.Result)
	}

	close(release)
	seen := map[string]bool{}
	for len(seen) < 2 {
		seen[string(tc.read(t).ID)] = true
	}
	if !seen["1"] || !seen["3"] {
		t.Fatalf("answered ids %v, want the running call 1 and the newest call 3", seen)
	}

	for _, p := range applied() {
		if p.Percent == 50 {
			t.Fatalf("the superseded value still reached the device: %v", applied())
		}
	}
}

// WholeStateKey is the key both shipped whole-state setters use. An empty
// return means never coalesce, which would drop them back to a 64-deep FIFO and
// replay every value a temperature drag passed through.
func TestWholeStateKeyIsOneNonEmptyKeyForEveryCall(t *testing.T) {
	first := WholeStateKey(json.RawMessage(`{"low":3000,"high":6500}`))
	second := WholeStateKey(json.RawMessage(`{"low":4500,"high":6500}`))
	if first == "" {
		t.Fatal("WholeStateKey returned the empty key, which never coalesces")
	}
	if first != second {
		t.Fatalf("WholeStateKey gave %q and %q for two calls, want one shared key", first, second)
	}
}

// The shipped key, end to end: a whole-state setter supersedes its waiting call
// whatever params the two carry.
func TestWholeStateSetterSupersedesWhateverTheParams(t *testing.T) {
	srv, dial := startTestServer(t)
	release := make(chan struct{})
	entered := make(chan struct{}, 4)
	srv.RegisterLatest("gamma", "wayland.gamma.setTemperature", func(params json.RawMessage) (any, error) {
		entered <- struct{}{}
		<-release
		return string(params), nil
	}, WholeStateKey)
	t.Cleanup(func() { close(release) })

	tc := dial(t)
	tc.sendID(t, "1", "wayland.gamma.setTemperature", map[string]any{"low": 3000, "high": 6500})
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("the handler never started")
	}
	tc.sendID(t, "2", "wayland.gamma.setTemperature", map[string]any{"low": 4000, "high": 6500})
	tc.sendID(t, "3", "wayland.gamma.setTemperature", map[string]any{"low": 5000, "high": 6500})

	superseded := tc.read(t)
	if string(superseded.ID) != "2" {
		t.Fatalf("superseded reply id = %s, want the replaced call 2; differing params must still share one key", superseded.ID)
	}
	result, ok := superseded.Result.(map[string]any)
	if !ok || result["superseded"] != true {
		t.Fatalf("replaced call result = %v, want a success marked superseded", superseded.Result)
	}
}

// TestKeepLatestKeepsOneSlotPerKey pins the per-key slot. Keyed by method alone,
// the write to the second display would evict the first display's waiting write
// and that display would never be written at all.
func TestKeepLatestKeepsOneSlotPerKey(t *testing.T) {
	srv, dial := startTestServer(t)
	release, applied := blockingSetter(t, srv)

	tc := dial(t)
	tc.sendID(t, "1", "brightness.setBrightness", map[string]any{"device": "eDP-1", "percent": 1})
	awaitHandlerEntered(t, applied)

	devices := []string{"DP-1", "DP-2", "HDMI-A-1"}
	for i, device := range devices {
		tc.sendID(t, strconv.Itoa(10+i), "brightness.setBrightness", map[string]any{"device": device, "percent": 1})
	}

	close(release)
	for i := 0; i < len(devices)+1; i++ {
		if resp := tc.read(t); resp.Error != "" {
			t.Fatalf("call %s answered %q", resp.ID, resp.Error)
		}
	}

	written := map[string]bool{}
	for _, p := range applied() {
		written[p.Device] = true
	}
	for _, device := range devices {
		if !written[device] {
			t.Fatalf("%s was never written: %v; on a lock blackout that display stays lit", device, applied())
		}
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
