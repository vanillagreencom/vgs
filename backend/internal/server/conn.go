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
// but stops reading must not block broadcaster goroutines forever; on timeout
// the connection is dropped instead.
const writeTimeout = 5 * time.Second

// conn wraps a client connection with a write lock so responses and broadcasts
// from different goroutines never interleave on the wire.
type conn struct {
	uc      *net.UnixConn
	log     *slog.Logger
	writeMu sync.Mutex
	closed  bool
}

func newConn(uc *net.UnixConn, log *slog.Logger) *conn {
	if log == nil {
		log = slog.Default()
	}
	return &conn{uc: uc, log: log}
}

// send marshals resp and writes it as one newline-delimited frame under a write
// deadline. Marshal failures for a request (resp has an ID) are downgraded to an
// error frame so the caller fails fast instead of hanging; write errors (peer
// gone or too slow) are terminal and close the connection.
func (c *conn) send(resp protocol.Response) {
	b, err := json.Marshal(resp)
	if err != nil {
		c.log.Error("marshal response failed", "err", err)
		if resp.ID == nil {
			return // an unserializable broadcast event: nothing safe to send
		}
		fallback, ferr := json.Marshal(protocol.Response{ID: resp.ID, Error: "internal: result not serializable"})
		if ferr != nil {
			return
		}
		b = fallback
	}
	b = append(b, '\n')

	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if c.closed {
		return
	}
	_ = c.uc.SetWriteDeadline(time.Now().Add(writeTimeout))
	if _, err := c.uc.Write(b); err != nil {
		// Peer disconnects are expected. Debug logging keeps other write errors
		// available for diagnosis.
		c.log.Debug("connection write failed, dropping", "err", err)
		c.closed = true
		c.uc.Close()
	}
}

func (c *conn) close() {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if c.closed {
		return
	}
	c.closed = true
	c.uc.Close()
}
