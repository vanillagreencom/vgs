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
// writer. Events coalesce per service, so this depth is reached only by a peer
// that has stopped draining many distinct services at once. Dropping frames
// would leave that peer silently out of date, so the connection ends instead.
const outboundDepth = 256

// outFrame is one queued wire frame. service names the subscription event it
// carries and is empty for a request response, which never coalesces because a
// client is waiting on that exact id.
type outFrame struct {
	service string
	resp    protocol.Response
}

// conn wraps a client connection with a bounded outbound queue drained by one
// writer goroutine. Every caller of send and sendEvent returns immediately, so
// a slow or stalled peer cannot delay a service's event loop.
type conn struct {
	uc  *net.UnixConn
	log *slog.Logger

	mu     sync.Mutex
	cond   *sync.Cond
	queue  []*outFrame
	latest map[string]*outFrame
	closed bool
}

func newConn(uc *net.UnixConn, log *slog.Logger) *conn {
	if log == nil {
		log = slog.Default()
	}
	c := &conn{uc: uc, log: log, latest: map[string]*outFrame{}}
	c.cond = sync.NewCond(&c.mu)
	go c.writeLoop()
	return c
}

// send queues a request response for the writer goroutine.
func (c *conn) send(resp protocol.Response) {
	c.enqueue(&outFrame{resp: resp})
}

// sendEvent queues a subscription push for service. A push for the same service
// that is still waiting for the writer is replaced in place, so a slow reader
// receives each service's latest state rather than a backlog of stale ones.
func (c *conn) sendEvent(service string, data any) {
	c.enqueue(&outFrame{
		service: service,
		resp:    protocol.Response{Result: protocol.Event{Service: service, Data: data}},
	})
}

func (c *conn) enqueue(f *outFrame) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return
	}
	if f.service != "" {
		if queued, ok := c.latest[f.service]; ok {
			queued.resp = f.resp
			return
		}
	}
	if len(c.queue) >= outboundDepth {
		c.log.Warn("outbound queue full, dropping connection", "depth", len(c.queue))
		c.closeLocked()
		return
	}
	c.queue = append(c.queue, f)
	if f.service != "" {
		c.latest[f.service] = f
	}
	c.cond.Signal()
}

// writeLoop is the only goroutine that writes to the socket, so frames from
// different callers never interleave on the wire.
func (c *conn) writeLoop() {
	for {
		c.mu.Lock()
		for len(c.queue) == 0 && !c.closed {
			c.cond.Wait()
		}
		if c.closed {
			c.mu.Unlock()
			return
		}
		f := c.queue[0]
		c.queue = c.queue[1:]
		if c.latest[f.service] == f {
			delete(c.latest, f.service)
		}
		c.mu.Unlock()

		if !c.write(f.resp) {
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
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closeLocked()
}

func (c *conn) closeLocked() {
	if c.closed {
		return
	}
	c.closed = true
	c.queue = nil
	c.latest = nil
	c.uc.Close()
	// Release the writer goroutine, which is otherwise parked on an empty queue.
	c.cond.Broadcast()
}
