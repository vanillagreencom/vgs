package tailscale

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os/exec"
	"time"
)

// The ipn bus watcher.
//
// Without it the backend only ever answers tailscale.getStatus on demand and
// re-broadcasts after its own write actions, so every transition VGS did not
// itself initiate is invisible: tailscaled finishing startup (the common case
// on a cold boot, where the shell's first and only read lands minutes before
// the daemon reaches Running), `tailscale up`/`down` from a terminal, another
// client, or the control plane expiring the node.
//
// The bus is consumed through `tailscale debug watch-ipn`, the supported CLI
// front end for tailscaled's LocalAPI /localapi/v0/watch-ipn-bus. Going through
// the CLI rather than dialling the LocalAPI socket directly keeps the operator
// mechanism (`tailscale set --operator=$USER`) in charge of access — the
// tailscaled socket is root-owned on many distributions — and matches how every
// other call in this service reaches tailscaled.
//
// A frame is treated purely as an edge: the payload is never parsed for state
// and never logged. ipn notifications carry Prefs.Config.PrivateNodeKey and the
// full netmap, so the only safe thing to do with the bytes is to discard them.
// On any frame the watcher re-runs the normal status path and broadcasts that,
// which also means subscribers keep receiving exactly the shape they handle
// today.

const (
	// Frames arrive in bursts while a netmap settles. The first unserved frame
	// opens a window; every frame landing inside it collapses into the same
	// push, and the push happens when the window closes whether or not traffic
	// has stopped.
	//
	// This is deliberately NOT a trailing-edge debounce. A debounce re-arms on
	// each frame, so a stream arriving faster than the window postpones the push
	// indefinitely — sustained bus traffic, which is exactly what a netmap burst
	// is, would suppress every watcher-driven broadcast until it went quiet.
	// Waiting for quiet buys nothing here anyway: pushStatus re-reads the
	// current status, so a push mid-burst is as truthful as one after it.
	watchCoalesceWindow = 400 * time.Millisecond
	// Floor on time between status reads, so a pathological frame rate cannot
	// turn into a `tailscale status` fork bomb. It can only ever lengthen the
	// wait, never shorten the coalescing window below its own value.
	watchMinInterval = 2 * time.Second
	// Restart backoff bounds for a watcher process that keeps exiting.
	watchBackoffMin = 1 * time.Second
	watchBackoffMax = 30 * time.Second
	// A watcher that survives this long counts as having worked, so the next
	// exit starts its backoff from scratch rather than inheriting a penalty.
	watchHealthyAfter = 60 * time.Second
	// Consecutive immediate failures before the supervisor gives up. Reached
	// when the installed tailscale has no `debug watch-ipn` at all; spinning on
	// that forever would just be a log flood.
	watchMaxFastFailures = 5
)

// startWatch launches the supervised ipn bus watcher.
func (m *Manager) startWatch() {
	if m.watchCtx == nil {
		m.watchCtx, m.watchStop = context.WithCancel(context.Background())
	}
	go m.superviseWatch()
}

// watcherActive answers one question: can a push arrive right now? True only
// while a watcher child is actually running — not merely while a supervisor
// exists. It is false before the first child starts, false during every restart
// backoff, and false permanently once supervision gives up.
//
// Reporting it for the supervisor rather than the child was wrong: the shell
// does not care whether something intends to watch, it uses this to decide how
// long it can go without asking, and during a backoff gap nothing can push. It
// rides along in every State so the shell can pick its cadence from what is
// actually running rather than from the capability alone — a capability is
// advertised once at registration and cannot be withdrawn.
func (m *Manager) watcherActive() bool { return m.watchAlive.Load() }

// setWatcherAlive records the child's liveness and, on a change, pushes a fresh
// status so subscribers learn at the transition instead of at their next poll —
// which for a watching backend is up to five minutes away, i.e. exactly the
// staleness this flag exists to prevent.
func (m *Manager) setWatcherAlive(alive bool) {
	if m.watchAlive.Swap(alive) == alive {
		return
	}
	m.pulse()
}

// superviseWatch keeps exactly one watcher process alive until Close.
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
		// runWatch already cleared the flag when the child exited, so the shell
		// is told it is on its own for the whole backoff, not just after the
		// give-up below.
		if fastFailures >= watchMaxFastFailures {
			m.log.Error("tailscale ipn bus watcher keeps failing immediately; giving up "+
				"(status will only update on demand — does this tailscale build have `debug watch-ipn`?)",
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

// runWatch reads one watcher process to completion.
func (m *Manager) runWatch(ctx context.Context) error {
	// --netmap=true is already the CLI default, but stated explicitly: peer
	// online/offline transitions reach the bus through the netmap, and those
	// are what the widget's peer list shows.
	cmd := exec.CommandContext(ctx, m.tailscale, "debug", "watch-ipn", "--netmap=true")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	m.setWatcherAlive(true)
	// From here every exit path must clear it again: until a replacement child
	// is running, no push can arrive, and a status read during the restart
	// backoff must say so.
	defer m.setWatcherAlive(false)
	readErr := m.readFrames(stdout, m.pulse)
	if readErr != nil {
		// The reader gave up on output it could not parse, but the child is
		// very likely still alive and simply idle — waiting for the next
		// tailscaled event. Closing the read end does not disturb a process
		// that is not writing, so Wait would block forever and supervision
		// would never restart, never count a failure, and never reach its
		// give-up limit. Terminate it explicitly.
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
	}
	_ = stdout.Close()
	waitErr := cmd.Wait()
	if readErr != nil {
		return readErr
	}
	return waitErr
}

// readFrames consumes concatenated JSON notifications and calls onFrame for
// each one. The frame contents are deliberately discarded: see the file header.
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

// pulse schedules a coalesced status read. Frames arriving while a push is
// already pending collapse into it and — importantly — do NOT postpone it, so
// the wait has a hard ceiling of the delay computed for the first frame.
func (m *Manager) pulse() {
	m.watchMu.Lock()
	defer m.watchMu.Unlock()
	if m.watchDone() {
		return
	}
	if m.pushTimer != nil {
		// A push is already scheduled; this frame is covered by it.
		return
	}
	if m.pushing {
		// A read is in flight. Starting a second one would put two `tailscale
		// status` calls in the air at once — each may take up to the 12s
		// command timeout while the scheduling floor is 2s — and they would
		// broadcast in completion order, so an older answer could land after a
		// newer one and make the shell's state go backwards. Remember the frame
		// instead; the read in flight re-pulses when it lands.
		m.pushMissed = true
		return
	}
	// The larger of the two: the coalescing window is a minimum wait, and the
	// min-interval remainder can only extend it.
	delay := watchCoalesceWindow
	if remainder := watchMinInterval - time.Since(m.lastPush); remainder > delay {
		delay = remainder
	}
	m.pushTimer = time.AfterFunc(delay, m.pushStatus)
}

// pushStatus re-reads the truthful status and broadcasts it to subscribers.
//
// Exactly one of these runs at a time. The slot is held until the read has been
// broadcast, so watcher-driven broadcasts are emitted in the order their reads
// started — a push can never hand the shell a state older than the one it just
// gave it. Frames that arrive meanwhile are not lost: they set pushMissed and
// are served by a fresh pulse as soon as this one finishes.
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
		// Never broadcast a fabricated "disconnected": a failed read is not a
		// state, and overwriting a good snapshot with one would recreate the
		// bug this watcher exists to fix.
		m.log.Warn("tailscale status read after ipn event failed", "err", err)
		return
	}
	m.log.Debug("tailscale ipn event", "backendState", state.BackendState, "connected", state.Connected)
	m.srv.Broadcast("tailscale", state)
}

// stopWatch cancels the watcher and any pending push.
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
