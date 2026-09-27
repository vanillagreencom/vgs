package execbound

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// ChildStopGrace is how long Stop waits after SIGTERM before it sends SIGKILL.
const ChildStopGrace = 2 * time.Second

// ChildOptions configures a long-lived child's output.
type ChildOptions struct {
	// Stdout pipes the child's standard output to Child.Stdout.
	Stdout bool
	// Stderr receives the child's standard error; nil discards it.
	Stderr io.Writer
}

// Child is a long-lived watcher process: it runs until it exits or is stopped,
// not for one output read. The kernel sends it SIGTERM when the backend dies,
// so a backend that exits without running Stop leaves no orphan for its
// supervised replacement to duplicate. The child leads a process group of its
// own, and Stop ends that group.
type Child struct {
	cmd    *exec.Cmd
	stdout *os.File
	done   chan struct{}
	err    error

	// mu orders group signals against the leader's exit. The waiter takes it
	// while the exited leader is still unreaped, and a reaped leader's pid can
	// name another process group; no signal goes to the group once exited is set.
	mu     sync.Mutex
	exited bool
}

// StartChild starts name as a long-lived child. When ctx ends the child is
// stopped as by Stop. Pdeathsig is tied to the thread that forks the child; the
// Go runtime ends a thread only for a goroutine that exits while locked to it,
// and nothing that starts a child here locks one.
func StartChild(ctx context.Context, opts ChildOptions, name string, args ...string) (*Child, error) {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGTERM}
	cmd.Stderr = opts.Stderr
	// A descendant that left the group can hold the stderr copy open; bound the
	// wait on it the way one-shot commands do.
	cmd.WaitDelay = DefaultWaitDelay
	c := &Child{cmd: cmd, done: make(chan struct{})}

	// os/exec closes a StdoutPipe reader inside Wait, which the waiter calls as
	// soon as the leader exits and so could drop output the caller has not read.
	// A pipe of our own stays open until the caller closes it.
	var writer *os.File
	if opts.Stdout {
		r, w, err := os.Pipe()
		if err != nil {
			return nil, err
		}
		c.stdout, writer = r, w
		cmd.Stdout = w
	}
	err := cmd.Start()
	if writer != nil {
		writer.Close()
	}
	if err != nil {
		if c.stdout != nil {
			c.stdout.Close()
		}
		return nil, err
	}

	go c.wait()
	go func() {
		select {
		case <-ctx.Done():
			c.Stop()
		case <-c.done:
		}
	}()
	return c, nil
}

// Stdout returns the read end of the child's standard output, or nil when
// ChildOptions.Stdout was false. It reaches EOF once every process holding the
// write end has exited. The caller closes it.
func (c *Child) Stdout() *os.File { return c.stdout }

// Done is closed once the child has exited and been reaped.
func (c *Child) Done() <-chan struct{} { return c.done }

// Err returns the child's wait error. It is valid once Done is closed.
func (c *Child) Err() error { return c.err }

// Stop sends SIGTERM to the child's process group, sends SIGKILL after
// ChildStopGrace if the leader has not exited, and returns once the leader is
// reaped. It is safe to call more than once and after the child has exited.
func (c *Child) Stop() {
	c.signalGroup(syscall.SIGTERM)
	timer := time.NewTimer(ChildStopGrace)
	defer timer.Stop()
	select {
	case <-c.done:
		return
	case <-timer.C:
	}
	c.signalGroup(syscall.SIGKILL)
	<-c.done
}

func (c *Child) signalGroup(sig syscall.Signal) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.exited {
		return
	}
	_ = syscall.Kill(-c.cmd.Process.Pid, sig)
}

// wait learns of the leader's exit without reaping it, ends what is left of
// its group while the zombie still pins the group id, and then reaps it.
func (c *Child) wait() {
	pid := c.cmd.Process.Pid
	var info unix.Siginfo
	var err error
	for {
		err = unix.Waitid(unix.P_PID, pid, &info, unix.WEXITED|unix.WNOWAIT, nil)
		if !errors.Is(err, unix.EINTR) {
			break
		}
	}
	c.mu.Lock()
	if err == nil {
		_ = syscall.Kill(-pid, syscall.SIGKILL)
	}
	c.exited = true
	c.mu.Unlock()
	c.err = c.cmd.Wait()
	close(c.done)
}
