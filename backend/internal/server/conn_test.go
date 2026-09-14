package server

import (
	"encoding/json"
	"net"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"vshell/backend/internal/protocol"
)

// newQueueConn builds a conn over a real Unix socket without starting its
// writer goroutine, so a test can inspect the outbound queue between an enqueue
// and the write that would drain it.
func newQueueConn(t *testing.T) *conn {
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

	c := &conn{uc: a.uc, log: discardLogger(), latest: map[string]*outFrame{}}
	c.cond = sync.NewCond(&c.mu)
	return c
}

// dataOf reads the event payload a queued frame would put on the wire.
func dataOf(t *testing.T, f *outFrame) any {
	t.Helper()
	ev, ok := f.resp.Result.(protocol.Event)
	if !ok {
		t.Fatalf("frame result is %T, want protocol.Event", f.resp.Result)
	}
	return ev.Data
}

func TestQueuedEventsCoalescePerService(t *testing.T) {
	c := newQueueConn(t)

	c.sendEvent("network", "first")
	c.sendEvent("gamma", "gamma-only")
	c.sendEvent("network", "second")
	c.sendEvent("network", "third")

	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.queue) != 2 {
		t.Fatalf("queue depth = %d, want 2 (one frame per service)", len(c.queue))
	}
	if got := dataOf(t, c.queue[0]); got != "third" {
		t.Fatalf("network frame carries %v, want the newest state %q", got, "third")
	}
	if c.queue[0].service != "network" {
		t.Fatalf("first frame service = %q, want network to keep its queue position", c.queue[0].service)
	}
	if got := dataOf(t, c.queue[1]); got != "gamma-only" {
		t.Fatalf("gamma frame carries %v, want %q", got, "gamma-only")
	}
}

func TestQueuedResponsesNeverCoalesce(t *testing.T) {
	c := newQueueConn(t)

	c.send(protocol.Response{ID: json.RawMessage("1"), Result: "one"})
	c.send(protocol.Response{ID: json.RawMessage("2"), Result: "two"})

	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.queue) != 2 {
		t.Fatalf("queue depth = %d, want 2: each id has a caller waiting on it", len(c.queue))
	}
}

func TestOutboundOverflowClosesConnection(t *testing.T) {
	c := newQueueConn(t)

	for i := 0; i < outboundDepth; i++ {
		c.sendEvent(serviceName(i), i)
	}
	c.mu.Lock()
	depth, closed := len(c.queue), c.closed
	c.mu.Unlock()
	if depth != outboundDepth || closed {
		t.Fatalf("after %d distinct services: depth %d closed %v, want depth %d and open", outboundDepth, depth, closed, outboundDepth)
	}

	c.sendEvent(serviceName(outboundDepth), "overflow")
	c.mu.Lock()
	closed = c.closed
	c.mu.Unlock()
	if !closed {
		t.Fatal("connection stayed open past the outbound queue bound; a peer that stopped reading must be dropped, not buffered without limit")
	}
}

func serviceName(i int) string { return "svc-" + strconv.Itoa(i) }
