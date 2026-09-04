package tailscale

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"time"
)

// The ipn bus watcher detects tailscaled changes made outside VGS. It uses
// tailscale debug watch-ipn so CLI operator permissions control access. Frames
// can contain private node keys and network maps: discard their contents and
// request state through the normal status path.

const (
	// The first unserved frame starts a fixed window. Later frames share the
	// pending push without extending it, so sustained traffic cannot postpone
	// status reads indefinitely.
	watchCoalesceWindow = 400 * time.Millisecond
	// Floor on time between status reads, so a pathological frame rate cannot
	// turn into a `tailscale status` fork bomb. It can only ever lengthen the
	// wait, never shorten the coalescing window below its own value.
	watchMinInterval = 2 * time.Second
	watchBackoffMin  = 1 * time.Second
	watchBackoffMax  = 30 * time.Second
	// A watcher that survives this long counts as having worked, so the next
	// exit starts its backoff from scratch rather than inheriting a penalty.
	watchHealthyAfter = 60 * time.Second
	// Limit consecutive short-lived watcher runs so a startup failure cannot cause
	// endless restarts.
	watchMaxFastFailures = 5
	// watchStderrCap limits retained stderr so a noisy watcher cannot grow the
	// error buffer without bound.
	watchStderrCap = 4 * 1024
)

// boundedBuffer accumulates up to a fixed number of bytes and silently drops
// the rest, so a Writer built on it can never grow past that cap regardless
// of how much the source writes.
type boundedBuffer struct {
	buf       bytes.Buffer
	max       int
	truncated bool
}

// Write reports the full input length even when the retained buffer is full.
// Truncation must not become an I/O error for cmd.Wait.
func (b *boundedBuffer) Write(p []byte) (int, error) {
	if room := b.max - b.buf.Len(); room > 0 {
		if len(p) > room {
			b.buf.Write(p[:room])
			b.truncated = true
		} else {
			b.buf.Write(p)
		}
	} else if len(p) > 0 {
		b.truncated = true
	}
	return len(p), nil
}

// Len reports how many bytes were retained (not how many the source wrote).
func (b *boundedBuffer) Len() int { return b.buf.Len() }

// String returns what was captured, trimmed, with a marker appended when the
// source wrote more than fit.
func (b *boundedBuffer) String() string {
	s := strings.TrimSpace(b.buf.String())
	if b.truncated {
		if s != "" {
			s += " "
		}
		s += "…[truncated]"
	}
	return s
}

func (m *Manager) startWatch() {
	if m.watchCtx == nil {
		m.watchCtx, m.watchStop = context.WithCancel(context.Background())
	}
	go m.superviseWatch()
}

// watcherActive reports a running watcher child. It is false during restart
// backoff and after supervision stops, so the shell can choose its refresh
// interval from current liveness.
func (m *Manager) watcherActive() bool { return m.watchAlive.Load() }

// setWatcherAlive requests a status push on child-liveness changes so
// subscribers can adjust polling during restart gaps.
func (m *Manager) setWatcherAlive(alive bool) {
	if m.watchAlive.Swap(alive) == alive {
		return
	}
	m.pulse()
}

// superviseWatch restarts the watcher until Close or the immediate-failure
// limit.
func (m *Manager) superviseWatch() {
	backoff := watchBackoffMin
	fastFailures := 0
	for {
		if m.watchCtx.Err() != nil {
			return
		}
		start := time.Now()
		err := m.runWatch(m.watchCtx)
		if m.watchCtx.Err() != nil {
			return
		}
		if time.Since(start) >= watchHealthyAfter {
			backoff = watchBackoffMin
			fastFailures = 0
		} else {
			fastFailures++
		}
		if fastFailures >= watchMaxFastFailures {
			// Report the observed exit error and retained stderr; an exit alone does not
			// identify why the child failed.
			m.log.Error("tailscale ipn bus watcher keeps failing immediately; giving up "+
				"(status will only update on demand)",
				"err", err, "attempts", fastFailures)
			return
		}
		m.log.Warn("tailscale ipn bus watcher exited; restarting", "err", err, "in", backoff)
		select {
		case <-m.watchCtx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff < watchBackoffMax {
			backoff *= 2
			if backoff > watchBackoffMax {
				backoff = watchBackoffMax
			}
		}
	}
}

func (m *Manager) runWatch(ctx context.Context) error {
	// Invoke watch-ipn without flags. Notifications already include the state
	// changes used here; unsupported flags would cause repeated startup failures.
	stderr := &boundedBuffer{max: watchStderrCap}
	cmd := exec.CommandContext(ctx, m.tailscale, "debug", "watch-ipn")
	cmd.Stderr = stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	m.setWatcherAlive(true)
	// Clear child liveness on exit so status reads during restart backoff request
	// polling.
	defer m.setWatcherAlive(false)
	readErr := m.readFrames(stdout, m.pulse)
	if readErr != nil {
		// A parse error does not stop an idle child. Kill it before Wait so malformed
		// output cannot block supervision indefinitely.
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	}
	_ = stdout.Close()
	waitErr := cmd.Wait()
	if readErr != nil {
		return readErr
	}
	// Fold stderr into the returned error so a supervisor give-up names what
	// the child actually said, instead of the caller having to guess a cause
	// from a bare exit status.
	if waitErr != nil && stderr.Len() > 0 {
		return fmt.Errorf("%w: %s", waitErr, stderr.String())
	}
	return waitErr
}

// readFrames consumes concatenated JSON notifications and calls onFrame without
// retaining their contents. Notifications can contain private keys.
func (m *Manager) readFrames(r io.Reader, onFrame func()) error {
	br := bufio.NewReaderSize(r, 64*1024)
	// Some tailscale builds print a human "Connected." banner before the JSON.
	// Skip whole lines until the stream is positioned on a JSON value.
	for {
		b, err := br.Peek(1)
		if err != nil {
			return skipEOF(err)
		}
		if b[0] == '{' {
			break
		}
		if _, err := br.ReadString('\n'); err != nil {
			return skipEOF(err)
		}
	}

	dec := json.NewDecoder(br)
	for {
		// An empty struct still makes the decoder validate and consume one
		// whole JSON value, and retains nothing from the payload.
		var frame struct{}
		if err := dec.Decode(&frame); err != nil {
			return skipEOF(err)
		}
		onFrame()
	}
}

func skipEOF(err error) error {
	if errors.Is(err, io.EOF) {
		return nil
	}
	return err
}

// watchDone reports whether the watcher has been shut down. Nil-safe: a Manager
// built directly in a test has no watchCtx, and a nil context.Context interface
// cannot have Err() called on it.
func (m *Manager) watchDone() bool {
	if m.watchCtx == nil {
		return false
	}
	return m.watchCtx.Err() != nil
}

// pulse coalesces frames without extending an existing timer, so continuous
// traffic does not postpone the pending read.
func (m *Manager) pulse() {
	m.watchMu.Lock()
	defer m.watchMu.Unlock()
	if m.watchDone() {
		return
	}
	if m.pushTimer != nil {
		return
	}
	if m.pushing {
		// Only one watcher status read may run at a time. Otherwise reads can finish
		// out of order and publish stale state. Record an intervening frame for a read
		// after this one finishes.
		m.pushMissed = true
		return
	}
	delay := watchCoalesceWindow
	if remainder := watchMinInterval - time.Since(m.lastPush); remainder > delay {
		delay = remainder
	}
	m.pushTimer = time.AfterFunc(delay, m.pushStatus)
}

// pushStatus holds the watcher read slot through broadcast so watcher reads
// publish in start order. Frames received during the read request another pulse.
func (m *Manager) pushStatus() {
	m.watchMu.Lock()
	m.lastPush = time.Now()
	m.pushTimer = nil
	m.pushing = true
	m.watchMu.Unlock()

	defer func() {
		m.watchMu.Lock()
		m.pushing = false
		missed := m.pushMissed
		m.pushMissed = false
		m.watchMu.Unlock()
		if missed {
			m.pulse()
		}
	}()

	if m.watchDone() {
		return
	}
	state, err := m.status()
	if err != nil {
		// A failed read must preserve the last reported state rather than publish an
		// empty disconnected state.
		m.log.Warn("tailscale status read after ipn event failed", "err", err)
		return
	}
	m.log.Debug("tailscale ipn event", "backendState", state.BackendState, "connected", state.Connected)
	m.srv.Broadcast("tailscale", state)
}

func (m *Manager) stopWatch() {
	// Cancel first: setWatcherAlive would otherwise pulse a status read on the
	// way out of a daemon that is shutting down.
	if m.watchStop != nil {
		m.watchStop()
	}
	m.watchAlive.Store(false)
	m.watchMu.Lock()
	if m.pushTimer != nil {
		m.pushTimer.Stop()
		m.pushTimer = nil
	}
	m.watchMu.Unlock()
}
