package server

import (
	"encoding/json"
	"log/slog"
	"net"
	"sync"
	"time"

	"vshell/backend/internal/protocol"
)

// writeTimeout bounds a single frame write. A subscriber that stays connected
// but stops reading must not block its writer goroutine forever; on timeout the
// connection is dropped instead.
const writeTimeout = 5 * time.Second

// outboundDepth bounds the frames one connection may hold waiting for its
// writer. A peer that reaches it has stopped draining the socket, and dropping
// frames would leave it silently out of date, so the connection ends instead.
const outboundDepth = 256

// conn wraps a client connection with a bounded outbound queue drained by one
// writer goroutine. Every caller of send and sendEvent returns immediately, so
// a slow or stalled peer cannot delay a service's event loop.
type conn struct {
	uc  *net.UnixConn
	log *slog.Logger

	out *coalescingQueue[protocol.Response]

	// seqMu guards the frame numbering, and is held across the enqueue beneath
	// it so a conditional push cannot be overtaken between its check and its
	// own enqueue.
	seqMu sync.Mutex
	// seq counts every frame enqueued on this connection, and lastByService
	// records the number of the newest frame enqueued for each service. A
	// caller that reads state and pushes it a moment later uses them to tell
	// whether a newer frame for that service got there first.
	seq           uint64
	lastByService map[string]uint64

	closeOnce sync.Once
}

func newConn(uc *net.UnixConn, log *slog.Logger) *conn {
	if log == nil {
		log = slog.Default()
	}
	c := &conn{
		uc:            uc,
		log:           log,
		out:           newCoalescingQueue[protocol.Response](outboundDepth),
		lastByService: map[string]uint64{},
	}
	go c.writeLoop()
	return c
}

// send queues a request response for the writer goroutine. A response carries
// an id a caller is waiting on, so it never coalesces.
func (c *conn) send(resp protocol.Response) {
	c.seqMu.Lock()
	defer c.seqMu.Unlock()
	c.enqueueLocked("", "", resp)
}

// sendEvent queues a subscription push for service. When coalesce is set, a
// push for the same service that the writer has not taken yet is replaced in
// place, so a slow reader receives that service's latest state rather than a
// backlog. It is set only for a service whose every broadcast carries the whole
// of its state; see Server.CoalesceBroadcasts.
func (c *conn) sendEvent(service string, data any, coalesce bool) {
	c.seqMu.Lock()
	defer c.seqMu.Unlock()
	c.enqueueLocked(service, coalesceKey(service, coalesce), eventFrame(service, data))
}

// mark returns the connection's current frame number, for a caller about to
// read a service's state and push it afterwards.
func (c *conn) mark() uint64 {
	c.seqMu.Lock()
	defer c.seqMu.Unlock()
	return c.seq
}

// sendEventUnlessOvertaken queues a push for state read at mark, unless a frame for that
// service reached this connection after the read began. Such a frame carries
// state at least as new as the read, so pushing the read would put the older
// state last on the wire; for a service whose frames carry an edge the shell
// acts on, such as the lock flag, that older frame undoes the newer one.
func (c *conn) sendEventUnlessOvertaken(service string, data any, coalesce bool, mark uint64) {
	c.seqMu.Lock()
	defer c.seqMu.Unlock()
	if c.lastByService[service] > mark {
		return
	}
	c.enqueueLocked(service, coalesceKey(service, coalesce), eventFrame(service, data))
}

func eventFrame(service string, data any) protocol.Response {
	return protocol.Response{Result: protocol.Event{Service: service, Data: data}}
}

func coalesceKey(service string, coalesce bool) string {
	if coalesce {
		return service
	}
	return ""
}

// enqueueLocked adds one frame and numbers it. The caller holds seqMu, which is
// what makes a check-then-push atomic against a concurrent broadcast.
func (c *conn) enqueueLocked(service, key string, resp protocol.Response) {
	switch _, outcome := c.out.push(key, resp); outcome {
	case pushQueued, pushReplaced:
	case pushClosed:
		return
	case pushFull:
		c.log.Warn("outbound queue full, dropping connection", "depth", outboundDepth)
		c.close()
		return
	}
	c.seq++
	if service != "" {
		c.lastByService[service] = c.seq
	}
}

// writeLoop is the only goroutine that writes to the socket, so frames from
// different callers never interleave on the wire.
func (c *conn) writeLoop() {
	for {
		resp, ok := c.out.pop()
		if !ok {
			return
		}
		if !c.write(resp) {
			c.close()
			return
		}
	}
}

// write marshals resp and writes it as one newline-delimited frame under a
// write deadline. Marshal failures for a request (resp has an ID) are
// downgraded to an error frame so the caller fails fast instead of hanging. It
// reports whether the connection is still usable.
func (c *conn) write(resp protocol.Response) bool {
	b, err := json.Marshal(resp)
	if err != nil {
		c.log.Error("marshal response failed", "err", err)
		if resp.ID == nil {
			return true // an unserializable broadcast event: nothing safe to send
		}
		fallback, ferr := json.Marshal(protocol.Response{ID: resp.ID, Error: "internal: result not serializable"})
		if ferr != nil {
			return true
		}
		b = fallback
	}
	b = append(b, '\n')

	_ = c.uc.SetWriteDeadline(time.Now().Add(writeTimeout))
	if _, err := c.uc.Write(b); err != nil {
		// Peer disconnects are expected. Debug logging keeps other write errors
		// available for diagnosis.
		c.log.Debug("connection write failed, dropping", "err", err)
		return false
	}
	return true
}

func (c *conn) close() {
	c.closeOnce.Do(func() {
		// Closing the queue releases the writer goroutine, which is otherwise
		// parked waiting for a frame.
		c.out.close()
		c.uc.Close()
	})
}
