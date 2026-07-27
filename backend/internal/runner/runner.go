// Package runner is the long-lived parent process launched by `vshell run`. It
// owns the backend socket, exports VGS_SOCKET, spawns the backend daemon and
// Quickshell as children, and guarantees teardown (socket/pid/session unlink,
// child reap) on every exit path. Quickshell must not own backend lifetime, so
// this replaces the old `exec qs`.
//
// The backend services run in a supervised child process (`vshell-backend
// serve`) on a listener FD inherited from the runner: a panic in a service
// kills only the backend, the supervisor restarts it (capped backoff,
// crash-loop breaker), and because the runner keeps the listener open the
// socket never disappears — QML reconnects and resubscribes.
//
// The backend is never required for the shell to start: if the socket cannot be
// created securely, Quickshell is launched without VGS_SOCKET (backend-disabled,
// features degrade) rather than failing startup — bin/vshell has already exec'd
// this binary, so there is no bash-side `exec qs` fallback left.
package runner

import (
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"syscall"
)

// Options configures a runner invocation.
type Options struct {
	// QSArgs are extra args appended after `qs -c vshell`.
	QSArgs []string
	Log    *slog.Logger
}

var stalePattern = regexp.MustCompile(`^vshell-(\d+)\.(sock|pid|session)$`)

// Run performs the full lifecycle and returns Quickshell's exit code.
func Run(opts Options) (int, error) {
	log := opts.Log
	if log == nil {
		log = slog.Default()
	}

	// Install signal handling before any setup so a SIGTERM in the startup
	// window is not the default (no-teardown) death.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)

	st, err := setupSocket(log)
	if err != nil {
		// Fail closed on the socket (never create an insecure/shared one) but do
		// not block the shell: run Quickshell with the backend disabled.
		log.Warn("backend socket unavailable, starting Quickshell without backend", "err", err)
		return runQuickshell(log, sigCh, opts.QSArgs, "")
	}
	defer st.teardown()

	lnFile, err := listenerFile(st.ln)
	if err != nil {
		log.Warn("backend listener FD unavailable, starting Quickshell without backend", "err", err)
		return runQuickshell(log, sigCh, opts.QSArgs, "")
	}
	stopSupervisor := make(chan struct{})
	supervisorDone := make(chan struct{})
	go func() {
		defer close(supervisorDone)
		superviseBackend(lnFile, st.socketPath, stopSupervisor, log, func() {
			// Tear the socket down so clients get a clean connection failure
			// (backend unavailable) instead of connects that queue forever in
			// a backlog nobody will accept.
			st.ln.Close()
			if !st.override {
				_ = os.Remove(st.socketPath)
			}
		})
	}()
	defer func() {
		close(stopSupervisor)
		<-supervisorDone
		lnFile.Close()
	}()
	st.writeState(log)

	// The listener is bound (accept backlog live) before we hand VGS_SOCKET to
	// Quickshell, so the client's first connect succeeds instead of racing the
	// backend child's startup.
	return runQuickshell(log, sigCh, opts.QSArgs, st.socketPath)
}

// listenerFile duplicates the Unix listener's FD for inheritance by the
// backend child.
func listenerFile(ln net.Listener) (*os.File, error) {
	ul, ok := ln.(*net.UnixListener)
	if !ok {
		return nil, fmt.Errorf("listener is not a unix listener")
	}
	return ul.File()
}

// socketState owns the listener and runtime files for one run.
type socketState struct {
	ln          net.Listener
	socketPath  string
	pidPath     string
	sessionPath string
	override    bool
	once        sync.Once
}

// setupSocket resolves the runtime directory, clears stale files, and binds the
// socket at 0600. It returns an error (fail closed) if the runtime directory is
// missing or the socket cannot be created.
func setupSocket(log *slog.Logger) (*socketState, error) {
	runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeDir == "" {
		return nil, fmt.Errorf("XDG_RUNTIME_DIR is not set; refusing to create the backend socket in a shared directory")
	}

	removeStale(runtimeDir, log)

	pid := os.Getpid()
	override := os.Getenv("VGS_BACKEND_SOCKET")
	socketPath := override
	if socketPath == "" {
		socketPath = filepath.Join(runtimeDir, fmt.Sprintf("vshell-%d.sock", pid))
	}
	// Clear a leftover socket (pid recycle, or a stale file at an override
	// path) so listen does not fail with EADDRINUSE and silently start the
	// shell backend-disabled.
	_ = os.Remove(socketPath)

	ln, err := listen(socketPath)
	if err != nil {
		return nil, fmt.Errorf("listen on %s: %w", socketPath, err)
	}

	return &socketState{
		ln:          ln,
		socketPath:  socketPath,
		pidPath:     filepath.Join(runtimeDir, fmt.Sprintf("vshell-%d.pid", pid)),
		sessionPath: filepath.Join(runtimeDir, fmt.Sprintf("vshell-%d.session", pid)),
		override:    override != "",
	}, nil
}

func (st *socketState) writeState(log *slog.Logger) {
	pid := os.Getpid()
	writeFile(st.pidPath, strconv.Itoa(pid), log)
	writeFile(st.sessionPath, fmt.Sprintf("pid=%d\nsocket=%s\n", pid, st.socketPath), log)
}

func (st *socketState) teardown() {
	st.once.Do(func() {
		st.ln.Close()
		// Don't unlink a caller-provided debug socket path.
		if !st.override {
			_ = os.Remove(st.socketPath)
		}
		_ = os.Remove(st.pidPath)
		_ = os.Remove(st.sessionPath)
	})
}

// runQuickshell spawns `qs -c vshell` (with VGS_SOCKET set when socketPath is
// non-empty) and waits. A signal-initiated shutdown returns 0 (a clean stop, so
// systemd does not record it as a failure); otherwise Quickshell's exit code is
// propagated.
func runQuickshell(log *slog.Logger, sigCh chan os.Signal, qsArgs []string, socketPath string) (int, error) {
	if socketPath != "" {
		os.Setenv("VGS_SOCKET", socketPath)
	}

	cmd := exec.Command("qs", append([]string{"-c", "vshell"}, qsArgs...)...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	// systemd tracks the runner as the main pid; if the runner dies uncleanly,
	// an orphaned Quickshell would collide with the restarted service.
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
	if err := cmd.Start(); err != nil {
		return 1, fmt.Errorf("start quickshell: %w", err)
	}

	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()

	select {
	case sig := <-sigCh:
		log.Info("signal received, shutting down", "signal", sig.String())
		if cmd.Process != nil {
			_ = cmd.Process.Signal(syscall.SIGTERM)
		}
		<-waitCh
		return 0, nil
	case err := <-waitCh:
		if err != nil {
			log.Info("quickshell exited", "err", err)
		}
		return exitCode(cmd), nil
	}
}

func listen(socketPath string) (net.Listener, error) {
	// Restrict the socket to the owner from creation via umask, then assert 0600.
	old := syscall.Umask(0o177)
	ln, err := net.Listen("unix", socketPath)
	syscall.Umask(old)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		ln.Close()
		_ = os.Remove(socketPath)
		return nil, err
	}
	return ln, nil
}

// removeStale unlinks vshell-<pid>.{sock,pid,session} files whose owning process
// is gone, so a crashed prior run does not leave junk (or a dead socket the
// client would try to reach).
func removeStale(dir string, log *slog.Logger) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		m := stalePattern.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		pid, err := strconv.Atoi(m[1])
		if err != nil || processAlive(pid) {
			continue
		}
		if err := os.Remove(filepath.Join(dir, e.Name())); err == nil {
			log.Debug("removed stale runtime file", "file", e.Name())
		}
	}
}

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	// On Linux signal 0 probes existence without affecting the process.
	return syscall.Kill(pid, 0) == nil
}

func writeFile(path, content string, log *slog.Logger) {
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		log.Warn("failed to write runtime file", "path", path, "err", err)
	}
}

func exitCode(cmd *exec.Cmd) int {
	if cmd.ProcessState == nil {
		return 0
	}
	return cmd.ProcessState.ExitCode()
}
