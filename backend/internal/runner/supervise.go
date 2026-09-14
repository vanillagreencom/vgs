package runner

import (
	"log/slog"
	"net"
	"os"
	"os/exec"
	"sync/atomic"
	"syscall"
	"time"
)

// supervisionLimits bound backend restarts. Restarts back off from
// backoffInitial, doubling to backoffMax. breakerLimit exits inside
// breakerWindow trip the breaker: the runner leaves the backend down for the
// cool-down, then starts it again. The cool-down starts at cooldownInitial and
// doubles on each trip to cooldownMax. A run that outlives breakerWindow resets
// the backoff and the cool-down.
type supervisionLimits struct {
	backoffInitial  time.Duration
	backoffMax      time.Duration
	breakerWindow   time.Duration
	breakerLimit    int
	cooldownInitial time.Duration
	cooldownMax     time.Duration
	// stopGrace is how long a backend being stopped or restarted gets between
	// SIGTERM and SIGKILL.
	stopGrace time.Duration
}

var defaultLimits = supervisionLimits{
	backoffInitial:  500 * time.Millisecond,
	backoffMax:      5 * time.Second,
	breakerWindow:   60 * time.Second,
	breakerLimit:    5,
	cooldownInitial: 5 * time.Minute,
	cooldownMax:     time.Hour,
	stopGrace:       3 * time.Second,
}

// superviseBackend restarts the backend on the inherited listener until stop
// closes. The caller owns ln and lnFile and keeps the socket bound through
// restarts and cool-downs. A signal on restart replaces the backend at once.
// onGiveUp runs only when the runner cannot resolve its own executable, so it
// can close the socket rather than leave clients waiting on an unserved backlog.
func superviseBackend(ln *net.UnixListener, lnFile *os.File, socketPath string, stop <-chan struct{}, restart <-chan os.Signal, log *slog.Logger, onGiveUp func()) {
	exe, err := os.Executable()
	if err != nil {
		log.Error("backend supervision unavailable: cannot resolve own executable", "err", err)
		onGiveUp()
		return
	}
	command := func() *exec.Cmd {
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
		return cmd
	}
	supervise(command, ln, defaultLimits, stop, restart, log)
}

type backendOutcome int

const (
	backendExited backendOutcome = iota
	backendStopped
	backendRestartRequested
)

// supervise starts a backend from command and restarts it until stop closes. A
// signal on restart ends the running backend, or cuts short a pending backoff or
// cool-down, and starts a fresh backend with the crash history cleared. A start
// failure counts as an exit. During a cool-down the runner accepts and closes
// every connection on ln, so a client sees the backend unavailable at once
// instead of queueing requests that the next backend would run late.
func supervise(command func() *exec.Cmd, ln *net.UnixListener, limits supervisionLimits, stop <-chan struct{}, restart <-chan os.Signal, log *slog.Logger) {
	var exits []time.Time
	backoff := limits.backoffInitial
	cooldown := limits.cooldownInitial
	resetHistory := func() {
		log.Info("backend restart requested")
		exits = nil
		backoff = limits.backoffInitial
		cooldown = limits.cooldownInitial
	}
	for {
		select {
		case <-stop:
			return
		default:
		}

		cmd := command()
		started := time.Now()
		if err := cmd.Start(); err != nil {
			log.Error("backend start failed", "err", err)
		} else {
			log.Info("backend started", "pid", cmd.Process.Pid)
			switch awaitBackend(cmd, started, limits.stopGrace, stop, restart, log) {
			case backendStopped:
				return
			case backendRestartRequested:
				resetHistory()
				continue
			case backendExited:
			}
		}

		now := time.Now()
		if now.Sub(started) > limits.breakerWindow {
			backoff = limits.backoffInitial
			cooldown = limits.cooldownInitial
		}
		exits = append(pruneOld(exits, now.Add(-limits.breakerWindow)), now)
		delay := backoff
		endRefusing := func() {}
		if len(exits) >= limits.breakerLimit {
			log.Error("backend crash loop detected; holding it down for a cool-down and closing connections until it restarts",
				"exits", len(exits), "window", limits.breakerWindow, "cooldown", cooldown)
			delay = cooldown
			exits = nil
			cooldown = min(cooldown*2, limits.cooldownMax)
			endRefusing = refuseConnections(ln, log)
		} else {
			backoff = min(backoff*2, limits.backoffMax)
		}

		timer := time.NewTimer(delay)
		select {
		case <-stop:
			timer.Stop()
			endRefusing()
			return
		case <-restart:
			timer.Stop()
			endRefusing()
			resetHistory()
		case <-timer.C:
			endRefusing()
		}
	}
}

// refuseConnections accepts and closes every connection on ln until the
// returned function runs. That function ends the accept loop through a listener
// deadline, waits for it, and clears the deadline, so the next backend is the
// only acceptor once it starts.
func refuseConnections(ln *net.UnixListener, log *slog.Logger) func() {
	var ending atomic.Bool
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			conn, err := ln.Accept()
			if err != nil {
				if !ending.Load() {
					log.Warn("closing connections during the cool-down stopped; clients may queue until the backend restarts", "err", err)
				}
				return
			}
			conn.Close()
		}
	}()
	return func() {
		ending.Store(true)
		_ = ln.SetDeadline(time.Unix(1, 0))
		<-done
		_ = ln.SetDeadline(time.Time{})
	}
}

// awaitBackend waits for the started backend to exit, or ends it when stop
// closes or a restart arrives.
func awaitBackend(cmd *exec.Cmd, started time.Time, grace time.Duration, stop <-chan struct{}, restart <-chan os.Signal, log *slog.Logger) backendOutcome {
	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()

	outcome := backendStopped
	select {
	case <-stop:
	case <-restart:
		outcome = backendRestartRequested
	case err := <-waitCh:
		log.Warn("backend exited", "err", err, "uptime", time.Since(started).Round(time.Millisecond))
		return backendExited
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case <-waitCh:
	case <-timer.C:
		_ = cmd.Process.Kill()
		<-waitCh
	}
	return outcome
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
