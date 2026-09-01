// Package execbound constructs one-shot external commands whose Wait cannot
// outlive the context indefinitely, and resolves the terminal condition that
// bound introduces.
package execbound

import (
	"context"
	"errors"
	"os/exec"
	"time"
)

// DefaultWaitDelay bounds how long Output and CombinedOutput keep reading the
// stdout/stderr pipes after the context deadline kills the child. A descendant
// that inherited those pipes holds them open once the child is gone, and Wait
// reads toward an EOF that never arrives — the backend request wedges forever
// instead of failing at its timeout. The bound cannot abandon a child that is
// itself in uninterruptible sleep: Wait blocks in wait4 regardless.
const DefaultWaitDelay = 2 * time.Second

// Command is exec.CommandContext with DefaultWaitDelay applied. Use it for
// one-shot commands read through Output or CombinedOutput; long-lived watcher
// processes own their own lifecycle and do not belong here.
func Command(ctx context.Context, name string, args ...string) *exec.Cmd {
	return CommandWithDelay(ctx, DefaultWaitDelay, name, args...)
}

// CommandWithDelay is Command with a caller-chosen bound, for a service that
// tunes the delay to its own helper (see brightnessbridge).
func CommandWithDelay(ctx context.Context, delay time.Duration, name string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.WaitDelay = delay
	return cmd
}

// Output runs cmd.Output and classifies the result. CombinedOutput is the same
// for cmd.CombinedOutput. Both return the bytes read either way, so a caller
// that wants partial output on failure still gets it.
//
// Error precedence is os/exec's: a non-zero exit or a failed wait always beats
// the WaitDelay overrun, so *exec.ExitError reaches callers keying on exit
// codes or Stderr exactly as before. A bare exec.ErrWaitDelay therefore means
// the child itself exited successfully and only a descendant still held its
// pipes open; that is reported as success with the bytes already read, because
// discarding a complete result because an unrelated descendant is slow to exit
// is the worse failure.
//
// The context deadline is not classified here — it reaches the caller as the
// killed child's *exec.ExitError, and each call site names its own timeout from
// ctx.Err() with the tool's name.
func Output(cmd *exec.Cmd) ([]byte, error) {
	out, err := cmd.Output()
	return out, classify(err)
}

// CombinedOutput runs cmd.CombinedOutput under Output's classification.
func CombinedOutput(cmd *exec.Cmd) ([]byte, error) {
	out, err := cmd.CombinedOutput()
	return out, classify(err)
}

func classify(err error) error {
	var exitErr *exec.ExitError
	if err == nil || errors.As(err, &exitErr) || !errors.Is(err, exec.ErrWaitDelay) {
		return err
	}
	return nil
}
