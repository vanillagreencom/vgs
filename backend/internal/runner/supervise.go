package runner

import (
	"log/slog"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// Capped backoff limits restart frequency. breakerLimit exits inside
// breakerWindow stop supervision and leave the backend unavailable.
const (
	backoffInitial = 500 * time.Millisecond
	backoffMax     = 5 * time.Second
	breakerWindow  = 60 * time.Second
	breakerLimit   = 5
)

// superviseBackend restarts the backend on the inherited listener until stop
// closes or the crash limit is reached. The caller owns lnFile and keeps the
// socket open during restarts. onGiveUp lets the caller close it so clients do
// not wait on an unserved backlog.
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
