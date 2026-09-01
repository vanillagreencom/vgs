package execbound

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// maxBoundedElapsed is the wall clock a backend request can tolerate from a
// one-shot command whose descendant holds the pipes. It is deliberately a
// literal rather than an expression over DefaultWaitDelay, so raising that
// constant past what a request survives fails here instead of quietly slowing
// every timeout in the backend.
const maxBoundedElapsed = 5 * time.Second

func TestCommandSetsDefaultWaitDelay(t *testing.T) {
	cmd := Command(context.Background(), "true")
	if cmd.WaitDelay != DefaultWaitDelay {
		t.Fatalf("WaitDelay = %v, want %v", cmd.WaitDelay, DefaultWaitDelay)
	}
}

// The constant itself, pinned to a magnitude independent of its own value:
// zero disables the bound entirely, and anything beyond a few seconds outlives
// the request it is supposed to protect.
func TestDefaultWaitDelayStaysInASaneBand(t *testing.T) {
	if DefaultWaitDelay <= 0 || DefaultWaitDelay > 3*time.Second {
		t.Fatalf("DefaultWaitDelay = %v, want a bound in (0, 3s]", DefaultWaitDelay)
	}
}

func TestCommandWithDelayUsesTheGivenDelay(t *testing.T) {
	cmd := CommandWithDelay(context.Background(), 700*time.Millisecond, "true")
	if cmd.WaitDelay != 700*time.Millisecond {
		t.Fatalf("WaitDelay = %v, want 700ms", cmd.WaitDelay)
	}
}

// pipeHolder builds a command whose script backgrounds a child that inherits
// stdout and holds the pipe open after the script itself is gone. Without
// WaitDelay, Output reads that pipe toward an EOF that never comes and these
// tests hang until the go test timeout.
//
// The command runs in its own process group so cleanup can SIGKILL the group
// and take the holder with it. Recording the holder's PID instead would race:
// with WaitDelay removed these tests block until the holder exits on its own,
// by which point the PID is dead and free for reuse by anything on the machine.
func pipeHolder(t *testing.T, ctx context.Context, delay time.Duration, tail string) *exec.Cmd {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "pipe-holder")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nsleep 60 &\n"+tail), 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := CommandWithDelay(ctx, delay, path)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	t.Cleanup(func() {
		if cmd.Process != nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
	})
	return cmd
}

// The wedge this package exists to prevent: the context deadline kills the
// child, the descendant keeps the pipe, and Output must still return.
func TestCommandReturnsAfterDeadlineKill(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	cmd := pipeHolder(t, ctx, DefaultWaitDelay, "exec sleep 60\n")

	start := time.Now()
	_, err := cmd.Output()
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("Output succeeded; want the killed child's error")
	}
	if elapsed > maxBoundedElapsed {
		t.Fatalf("Output took %v, want under %v", elapsed, maxBoundedElapsed)
	}
}

// The child exits cleanly and only the descendant holds the pipe, so no
// deadline is involved: WaitDelay alone ends the read, and raw cmd.Output
// surfaces that as exec.ErrWaitDelay with the child's bytes intact.
func TestCommandReturnsAfterCleanExitWithHeldPipe(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cmd := pipeHolder(t, ctx, 300*time.Millisecond, "echo done\n")

	out, err := cmd.Output()

	if !errors.Is(err, exec.ErrWaitDelay) {
		t.Fatalf("err = %v, want exec.ErrWaitDelay", err)
	}
	if strings.TrimSpace(string(out)) != "done" {
		t.Fatalf("out = %q, want %q", out, "done")
	}
}

// The salvage contract: the same clean exit read through Output is a success
// with complete bytes, not an error a call site has to know how to interpret.
func TestOutputSalvagesCleanExitWithHeldPipe(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cmd := pipeHolder(t, ctx, 300*time.Millisecond, "echo done\n")

	out, err := Output(cmd)

	if err != nil {
		t.Fatalf("err = %v, want nil: the child exited 0 and its output was read", err)
	}
	if strings.TrimSpace(string(out)) != "done" {
		t.Fatalf("out = %q, want %q", out, "done")
	}
}

func TestCombinedOutputSalvagesCleanExitWithHeldPipe(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cmd := pipeHolder(t, ctx, 300*time.Millisecond, "echo done >&2\n")

	out, err := CombinedOutput(cmd)

	if err != nil {
		t.Fatalf("err = %v, want nil", err)
	}
	if strings.TrimSpace(string(out)) != "done" {
		t.Fatalf("out = %q, want %q", out, "done")
	}
}

// The control on the salvage: a non-zero exit must stay an *exec.ExitError
// even when the pipes are also held, or every call site keying on an exit code
// or Stderr — sysupdate's exit-2 "no updates", cups and tailscale reading
// ee.Stderr — silently reclassifies.
func TestOutputKeepsExitErrorOverWaitDelay(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	cmd := pipeHolder(t, ctx, 300*time.Millisecond, "echo partial\nexit 2\n")

	out, err := Output(cmd)

	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("err = %v, want *exec.ExitError", err)
	}
	if errors.Is(err, exec.ErrWaitDelay) {
		t.Fatalf("err = %v, want the exit error, not the WaitDelay overrun", err)
	}
	if exitErr.ExitCode() != 2 {
		t.Fatalf("exit code = %d, want 2", exitErr.ExitCode())
	}
	if strings.TrimSpace(string(out)) != "partial" {
		t.Fatalf("out = %q, want %q", out, "partial")
	}
}

func TestOutputPassesThroughOrdinaryExitError(t *testing.T) {
	cmd := Command(context.Background(), "sh", "-c", "echo boom >&2; exit 3")
	_, err := Output(cmd)

	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) {
		t.Fatalf("err = %v, want *exec.ExitError", err)
	}
	if exitErr.ExitCode() != 3 {
		t.Fatalf("exit code = %d, want 3", exitErr.ExitCode())
	}
	if strings.TrimSpace(string(exitErr.Stderr)) != "boom" {
		t.Fatalf("stderr = %q, want %q", exitErr.Stderr, "boom")
	}
}
