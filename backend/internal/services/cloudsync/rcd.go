package cloudsync

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"syscall"
	"time"
)

const (
	// rcdStartTimeout bounds how long we wait for a freshly spawned rcd to
	// answer core/version before treating the start as failed.
	rcdStartTimeout = 15 * time.Second
	// rcdCrashWindow / rcdCrashLimit form the crash-loop breaker: more than
	// rcdCrashLimit exits inside the window stops the supervisor and leaves the
	// service reporting an error instead of respawning forever.
	rcdCrashWindow = 60 * time.Second
	rcdCrashLimit  = 5
)

// rcd supervises exactly one `rclone rcd` child. It is the single owner of that
// process: nothing else in VGS may start one.
type rcd struct {
	binary string
	client *rcClient
	onDown func(err string)
	onUp   func(version string)

	mu  sync.Mutex
	cmd *exec.Cmd
	// starting protects the interval before d.cmd is assigned. Concurrent starts
	// could otherwise orphan a daemon holding a port and mounts.
	starting bool
	// done is closed by wait() once the current child has been reaped, so
	// close() can await the existing waiter instead of issuing a second,
	// unsupported concurrent Wait on the same process.
	done     chan struct{}
	closing  bool
	version  string
	lastErr  string
	crashes  []time.Time
	stopped  bool
	restartT *time.Timer
}

func newRCD(binary string, client *rcClient, onUp func(string), onDown func(string)) *rcd {
	return &rcd{binary: binary, client: client, onUp: onUp, onDown: onDown}
}

// start launches rcd and blocks until it answers or the start times out.
func (d *rcd) start() error {
	d.mu.Lock()
	if d.closing || d.cmd != nil || d.starting {
		d.mu.Unlock()
		return nil
	}
	if d.stopped {
		// The crash-loop breaker is honoured here, not only inside wait():
		// otherwise a stray start() call walks straight past it.
		d.mu.Unlock()
		return fmt.Errorf("rclone control daemon is stopped after repeated crashes")
	}
	d.starting = true
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		d.starting = false
		d.mu.Unlock()
	}()

	port, err := freeLoopbackPort()
	if err != nil {
		return fmt.Errorf("reserve control port: %w", err)
	}
	user, pass, err := randomCredentials()
	if err != nil {
		return fmt.Errorf("generate control credentials: %w", err)
	}

	// Bind the control API to loopback and require authentication because it can
	// access account credentials and run operations as this user. Pass credentials
	// through the environment because command arguments can be visible to other
	// local users.
	cmd := exec.Command(d.binary,
		"rcd",
		"--rc-addr", "127.0.0.1:"+strconv.Itoa(port),
		"--rc-web-gui=false",
		"--log-level", "NOTICE",
	)
	cmd.Env = append(os.Environ(),
		"RCLONE_RC_USER="+user,
		"RCLONE_RC_PASS="+pass,
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// stdout/stderr are left unattached: rclone's rc log can contain remote
	// paths, and nothing here parses it (the port is chosen by us, not read
	// back from the log).
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start rclone rcd: %w", err)
	}

	d.client.setEndpoint("http://127.0.0.1:"+strconv.Itoa(port), user, pass)

	done := make(chan struct{})
	d.mu.Lock()
	d.cmd = cmd
	d.done = done
	d.mu.Unlock()

	go d.wait(cmd, done)

	version, err := d.awaitReady()
	if err != nil {
		d.kill(cmd)
		d.client.clearEndpoint()
		return err
	}

	d.mu.Lock()
	d.version = version
	d.lastErr = ""
	d.mu.Unlock()
	if d.onUp != nil {
		d.onUp(version)
	}
	return nil
}

// awaitReady polls core/version until the daemon answers.
func (d *rcd) awaitReady() (string, error) {
	deadline := time.Now().Add(rcdStartTimeout)
	var lastErr error
	for time.Now().Before(deadline) {
		var v rcVersion
		if err := d.client.callTimeout("core/version", nil, &v, 2*time.Second); err == nil {
			return v.Version, nil
		} else {
			lastErr = err
		}
		time.Sleep(150 * time.Millisecond)
	}
	if lastErr != nil {
		return "", fmt.Errorf("rclone control daemon did not start: %w", lastErr)
	}
	return "", fmt.Errorf("rclone control daemon did not start")
}

// wait reaps the child and restarts it unless we are shutting down or the
// crash-loop breaker has tripped.
func (d *rcd) wait(cmd *exec.Cmd, done chan struct{}) {
	err := cmd.Wait()
	close(done)

	d.mu.Lock()
	if d.closing || d.cmd != cmd {
		d.mu.Unlock()
		return
	}
	d.cmd = nil
	d.client.clearEndpoint()

	msg := "rclone control daemon exited"
	if err != nil {
		msg = "rclone control daemon exited: " + err.Error()
	}
	d.lastErr = msg

	now := time.Now()
	kept := d.crashes[:0]
	for _, t := range d.crashes {
		if now.Sub(t) < rcdCrashWindow {
			kept = append(kept, t)
		}
	}
	d.crashes = append(kept, now)
	tripped := len(d.crashes) > rcdCrashLimit
	if tripped {
		d.stopped = true
		d.lastErr = "rclone control daemon keeps crashing; sync is stopped"
	}
	backoff := time.Duration(len(d.crashes)) * time.Second
	if backoff > 15*time.Second {
		backoff = 15 * time.Second
	}
	d.mu.Unlock()

	if d.onDown != nil {
		d.onDown(msg)
	}
	if tripped {
		return
	}

	d.mu.Lock()
	if d.closing {
		d.mu.Unlock()
		return
	}
	d.restartT = time.AfterFunc(backoff, func() {
		if err := d.start(); err != nil && d.onDown != nil {
			d.onDown(err.Error())
		}
	})
	d.mu.Unlock()
}

// ensure restarts a daemon that the breaker stopped, clearing the crash budget.
// Used by the explicit "retry" action in the UI.
func (d *rcd) ensure() error {
	d.mu.Lock()
	running := d.cmd != nil
	d.stopped = false
	d.crashes = nil
	d.mu.Unlock()
	if running {
		return nil
	}
	return d.start()
}

func (d *rcd) running() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.cmd != nil
}

func (d *rcd) info() (version string, lastErr string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.version, d.lastErr
}

// close stops the daemon for good. It asks politely via core/quit first so
// rclone can flush VFS caches and release mounts, then escalates.
func (d *rcd) close() {
	d.mu.Lock()
	d.closing = true
	cmd := d.cmd
	done := d.done
	d.cmd = nil
	if d.restartT != nil {
		d.restartT.Stop()
	}
	d.mu.Unlock()

	if cmd == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	_ = d.client.call(ctx, "core/quit", nil, nil)
	cancel()

	// Wait on the existing reaper: concurrent cmd.Wait calls can return ECHILD
	// before the child is gone, causing shutdown to skip a needed kill.
	if done == nil {
		d.kill(cmd)
		d.client.clearEndpoint()
		return
	}
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		d.kill(cmd)
	}
	d.client.clearEndpoint()
}

// kill terminates the whole process group: rclone mounts spawn helpers, and a
// stray fusermount child would keep a mount point busy.
func (d *rcd) kill(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	pgid, err := syscall.Getpgid(cmd.Process.Pid)
	if err == nil {
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
		return
	}
	_ = cmd.Process.Kill()
}

// freeLoopbackPort finds an available port by binding and releasing it. The port
// is not reserved for the subsequent daemon bind.
func freeLoopbackPort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer ln.Close()
	addr, ok := ln.Addr().(*net.TCPAddr)
	if !ok {
		return 0, fmt.Errorf("unexpected listener address type")
	}
	return addr.Port, nil
}

func randomCredentials() (string, string, error) {
	buf := make([]byte, 24)
	if _, err := rand.Read(buf); err != nil {
		return "", "", err
	}
	return "vshell-" + hex.EncodeToString(buf[:4]), hex.EncodeToString(buf[4:]), nil
}
