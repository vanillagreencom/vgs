// Package execbound bounds pipe reads for one-shot external commands and
// classifies their exit errors. Callers use the returned error so deadline and
// output-recovery precedence stays in one place. WaitDelay cannot bound a child
// stuck in uninterruptible sleep.
package execbound

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"path/filepath"
	"time"
)

// DefaultWaitDelay limits pipe reads after the context ends or the child exits.
// Descendants can hold inherited pipes open after the child is gone. It does not
// bound wait4 for a child in uninterruptible sleep.
const DefaultWaitDelay = 2 * time.Second

// ErrTimeout classifies a run whose context deadline ended. Callers add the tool
// name. The error chain also contains context.DeadlineExceeded.
var ErrTimeout = errors.New("timed out")

// Result is what a bounded run produced.
type Result struct {
	// Out is everything read from the pipes.
	Out []byte
	// Salvaged reports a clean child exit whose pipe reads ended at WaitDelay. Out
	// contains the bytes read and may include writes from descendants. The run logs
	// a warning because those descendants can remain alive.
	Salvaged bool
}

// Cmd is a one-shot command bound by both a WaitDelay and the context that
// built it, so the runner can classify the two together.
type Cmd struct {
	ctx context.Context
	cmd *exec.Cmd
	log *slog.Logger
}

// WithLogger sends this command's salvage warning to a service logger instead
// of slog.Default().
func (c *Cmd) WithLogger(log *slog.Logger) *Cmd {
	if log != nil {
		c.log = log
	}
	return c
}

// Command builds a bounded command with DefaultWaitDelay. Use it for one-shot
// commands read through Output or CombinedOutput; long-lived watcher processes
// own their own lifecycle and do not belong here.
func Command(ctx context.Context, name string, args ...string) *Cmd {
	return CommandWithDelay(ctx, DefaultWaitDelay, name, args...)
}

// CommandWithDelay builds a command with a caller-supplied pipe-read bound.
// Non-positive delays use DefaultWaitDelay because os/exec treats a zero
// WaitDelay as unbounded.
func CommandWithDelay(ctx context.Context, delay time.Duration, name string, args ...string) *Cmd {
	if delay <= 0 {
		delay = DefaultWaitDelay
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.WaitDelay = delay
	return &Cmd{ctx: ctx, cmd: cmd, log: slog.Default()}
}

// Exec exposes the underlying command for pre-start configuration such as
// SysProcAttr or Env. Do not run it directly: the classification lives here.
func (c *Cmd) Exec() *exec.Cmd { return c.cmd }

// Output runs the command and returns the bytes read, including partial output
// on failure. A non-zero exit status takes precedence over context errors. A
// bare exec.ErrWaitDelay becomes a successful Result with Salvaged set.
// Otherwise, an ended context supplies the error; a deadline produces
// ErrTimeout.
func (c *Cmd) Output() (Result, error) {
	out, err := c.cmd.Output()
	return c.report(classify(c.ctx, out, err))
}

// CombinedOutput runs the command under Output's classification.
func (c *Cmd) CombinedOutput() (Result, error) {
	out, err := c.cmd.CombinedOutput()
	return c.report(classify(c.ctx, out, err))
}

// Keep the warning here so callers cannot omit the report of a descendant
// holding pipes open.
func (c *Cmd) report(res Result, err error) (Result, error) {
	if res.Salvaged {
		c.log.Warn("command exited but a descendant held its pipes open; output may include the descendant's writes",
			"tool", filepath.Base(c.cmd.Path))
	}
	return res, err
}

// Interrupted reports a classified timeout or context cancellation.
func Interrupted(err error) bool {
	return errors.Is(err, ErrTimeout) || errors.Is(err, context.Canceled)
}

func classify(ctx context.Context, out []byte, err error) (Result, error) {
	res := Result{Out: out}
	if err == nil {
		return res, nil
	}
	// The child exited 0 and only the WaitDelay ended the read: a descendant
	// holds the pipes. os/exec discards that overrun when the child exited
	// non-zero, so an *exec.ExitError here is never the salvage case.
	var exitErr *exec.ExitError
	if errors.Is(err, exec.ErrWaitDelay) && !errors.As(err, &exitErr) {
		res.Salvaged = true
		return res, nil
	}
	// A real exit code takes precedence over a later deadline while descendants
	// hold pipes. CommandContext kills by signal, which produces no exit code.
	if errors.As(err, &exitErr) && exitErr.ExitCode() >= 0 {
		return res, err
	}
	if ctxErr := ctx.Err(); ctxErr != nil {
		if errors.Is(ctxErr, context.DeadlineExceeded) {
			return res, fmt.Errorf("%w: %w", ErrTimeout, ctxErr)
		}
		return res, ctxErr
	}
	return res, err
}
