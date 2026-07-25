package runner

import (
	"log/slog"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// Supervision policy: restart the backend child with capped backoff, but stop
// after breakerLimit exits inside breakerWindow — a persistently crashing
// backend must degrade the shell to backend-unavailable, not thrash forever.
const (
	backoffInitial = 500 * time.Millisecond
	backoffMax     = 5 * time.Second
	breakerWindow  = 60 * time.Second
	breakerLimit   = 5
)

// superviseBackend runs `vshell-backend serve` as a child on the inherited
// listener FD and restarts it when it dies. The runner keeps ownership of the
// listener, so the socket never disappears across backend restarts: connects
// made while the child is down queue in the accept backlog and are served by
// the next instance. Returns when stop is closed or the crash-loop breaker
// trips; onGiveUp runs on a breaker trip (or unrecoverable start failure) so
// the runner can tear the socket down and clients fail fast instead of
// hanging on a never-accepted connection. The caller owns lnFile.
func superviseBackend(lnFile *os.File, socketPath string, stop <-chan struct{}, log *slog.Logger, onGiveUp func()) {
	exe, err := os.Executable()
	if err != nil {
		log.Error("backend supervision unavailable: cannot resolve own executable", "err", err)
		onGiveUp()
		return
	}

	var exits []time.Time
	backoff := backoffInitial
	for {
		select {
		case <-stop:
			return
		default:
		}

		cmd := exec.Command(exe, "serve")
		cmd.Env = append(os.Environ(),
			"VGS_BACKEND_LISTEN_FD=3",
			"VGS_BACKEND_SOCKET="+socketPath,
		)
		cmd.ExtraFiles = []*os.File{lnFile}
		cmd.Stdout = os.Stderr
		cmd.Stderr = os.Stderr
		// If the runner dies without cleanup, the orphaned backend must not
		// linger on a socket the next run will unlink.
		cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}

		started := time.Now()
		if err := cmd.Start(); err != nil {
			log.Error("backend start failed", "err", err)
			onGiveUp()
			return
		}
		log.Info("backend started", "pid", cmd.Process.Pid)

		waitCh := make(chan error, 1)
		go func() { waitCh <- cmd.Wait() }()

		select {
		case <-stop:
			_ = cmd.Process.Signal(syscall.SIGTERM)
			select {
			case <-waitCh:
			case <-time.After(3 * time.Second):
				_ = cmd.Process.Kill()
				<-waitCh
			}
			return
		case err := <-waitCh:
			log.Warn("backend exited", "err", err, "uptime", time.Since(started).Round(time.Millisecond))
		}

		now := time.Now()
		exits = append(exits, now)
		exits = pruneOld(exits, now.Add(-breakerWindow))
		if len(exits) >= breakerLimit {
			log.Error("backend crash loop detected; giving up — shell continues without backend",
				"exits", len(exits), "window", breakerWindow)
			onGiveUp()
			return
		}

		// A child that ran healthily for a while earns a fresh backoff.
		if time.Since(started) > breakerWindow {
			backoff = backoffInitial
		}
		select {
		case <-stop:
			return
		case <-time.After(backoff):
		}
		backoff *= 2
		if backoff > backoffMax {
			backoff = backoffMax
		}
	}
}

func pruneOld(times []time.Time, cutoff time.Time) []time.Time {
	kept := times[:0]
	for _, t := range times {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	return kept
}
