// Package runner owns the backend listener and starts the backend daemon and
// Quickshell as children. It keeps the listener open during supervised backend
// restarts so connections can queue in the accept backlog. If secure socket
// creation fails, it starts Quickshell without the backend. Normal shutdown
// closes the listener, removes runtime files, and waits for children.
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
	// QSArgs are extra arguments appended to the Quickshell invocation.
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

	// Bind the listener before handing VGS_SOCKET to Quickshell so a connection can
	// queue while the backend starts.
	return runQuickshell(log, sigCh, opts.QSArgs, st.socketPath)
}

func listenerFile(ln net.Listener) (*os.File, error) {
	ul, ok := ln.(*net.UnixListener)
	if !ok {
		return nil, fmt.Errorf("listener is not a unix listener")
	}
	return ul.File()
}

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

// runQuickshell spawns the packaged config path when VSHELL_ROOT is available,
// otherwise `qs -c vshell` (with VGS_SOCKET set when socketPath is
// non-empty) and waits. A signal-initiated shutdown returns 0 (a clean stop, so
// systemd does not record it as a failure); otherwise Quickshell's exit code is
// propagated.
func runQuickshell(log *slog.Logger, sigCh chan os.Signal, qsArgs []string, socketPath string) (int, error) {
	if socketPath != "" {
		os.Setenv("VGS_SOCKET", socketPath)
	}

	baseArgs := []string{"-c", "vshell"}
	if root := os.Getenv("VSHELL_ROOT"); root != "" {
		configPath := filepath.Join(root, "quickshell", "vshell")
		if _, err := os.Stat(filepath.Join(configPath, "shell.qml")); err == nil {
			baseArgs = []string{"-p", configPath}
		}
	}
	cmd := exec.Command("qs", append(baseArgs, qsArgs...)...)
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
