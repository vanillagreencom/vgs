package server

import (
	"net"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"vshell/backend/internal/protocol"
)

// newIdleConn builds a conn over a real Unix socket without starting its writer
// goroutine, so a test can inspect what the peer would receive.
func newIdleConn(t *testing.T) *conn {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "q.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	type accepted struct {
		uc  *net.UnixConn
		err error
	}
	got := make(chan accepted, 1)
	go func() {
		nc, err := ln.Accept()
		if err != nil {
			got <- accepted{err: err}
			return
		}
		got <- accepted{uc: nc.(*net.UnixConn)}
	}()
	client, err := net.DialTimeout("unix", sock, 2*time.Second)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { client.Close() })
	a := <-got
	if a.err != nil {
		t.Fatalf("accept: %v", a.err)
	}
	t.Cleanup(func() { a.uc.Close() })

	return &conn{uc: a.uc, log: discardLogger(), out: newCoalescingQueue[protocol.Response](outboundDepth)}
}

// queuedEvents drains what the writer would put on the wire, as
// (service, data) pairs.
func queuedEvents(t *testing.T, c *conn) [][2]any {
	t.Helper()
	var out [][2]any
	for c.out.len() > 0 {
		resp, ok := c.out.pop()
		if !ok {
			break
		}
		ev, isEvent := resp.Result.(protocol.Event)
		if !isEvent {
			out = append(out, [2]any{"", resp.Result})
			continue
		}
		out = append(out, [2]any{ev.Service, ev.Data})
	}
	return out
}

func TestConnCoalescedEventsKeepOnlyTheNewest(t *testing.T) {
	c := newIdleConn(t)
	c.sendEvent("network", "first", true)
	c.sendEvent("network", "second", true)

	got := queuedEvents(t, c)
	if len(got) != 1 {
		t.Fatalf("queued %d frames, want 1 for a coalesced service: %v", len(got), got)
	}
	if got[0][1] != "second" {
		t.Fatalf("queued payload = %v, want the newest state", got[0][1])
	}
}

// An uncoalesced service carries distinct events under one name — a per-URL
// open request, a per-device pairing prompt. Replacing one with another loses
// it outright, with nothing to report it.
func TestConnUncoalescedEventsAreAllKept(t *testing.T) {
	c := newIdleConn(t)
	c.sendEvent("browser.open_requested", "https://one.example", false)
	c.sendEvent("browser.open_requested", "https://two.example", false)

	got := queuedEvents(t, c)
	if len(got) != 2 {
		t.Fatalf("queued %d frames, want both open requests: %v", len(got), got)
	}
	if got[0][1] != "https://one.example" || got[1][1] != "https://two.example" {
		t.Fatalf("queued payloads = %v, want both requests in order", got)
	}
}

func TestConnResponsesNeverCoalesce(t *testing.T) {
	c := newIdleConn(t)
	c.send(protocol.Response{Result: "one"})
	c.send(protocol.Response{Result: "two"})

	if got := c.out.len(); got != 2 {
		t.Fatalf("queued %d responses, want 2: each id has a caller waiting on it", got)
	}
}

func TestConnOutboundOverflowClosesConnection(t *testing.T) {
	c := newIdleConn(t)
	for i := 0; i < outboundDepth; i++ {
		c.sendEvent("svc-"+strconv.Itoa(i), i, false)
	}
	if got := c.out.len(); got != outboundDepth {
		t.Fatalf("queued %d frames, want the bound %d", got, outboundDepth)
	}

	c.sendEvent("one-too-many", "overflow", false)
	if _, outcome := c.out.push("probe", protocol.Response{}); outcome != pushClosed {
		t.Fatal("connection stayed open past the outbound bound; a peer that stopped reading must be dropped, not buffered without limit")
	}
}
