// Package execbound constructs one-shot external commands whose Wait cannot
// outlive the context indefinitely, and owns every terminal condition that
// bound introduces. A call site runs the command through this package and
// tests the returned error; it never inspects ctx.Err() or exec.ErrWaitDelay
// itself, so the deadline-versus-salvage ordering exists in one place.
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

// DefaultWaitDelay bounds how long Output and CombinedOutput keep reading the
// stdout/stderr pipes after the context deadline kills the child. A descendant
// that inherited those pipes holds them open once the child is gone, and Wait
// reads toward an EOF that never arrives — the backend request wedges forever
// instead of failing at its timeout. The bound cannot abandon a child that is
// itself in uninterruptible sleep: Wait blocks in wait4 regardless.
const DefaultWaitDelay = 2 * time.Second

// ErrTimeout classifies a run the context deadline ended. Call sites wrap it
// with their own tool name — "nmcli timed out", "hyprctl monitors timed out" —
// rather than surfacing this text. The context's own error stays in the chain,
// so errors.Is(err, context.DeadlineExceeded) still holds.
var ErrTimeout = errors.New("timed out")

// Result is what a bounded run produced.
type Result struct {
	// Out is everything read from the pipes.
	Out []byte
	// Salvaged reports that the child exited cleanly but a descendant held its
	// pipes open until the bound expired, so Out is the child's complete output
	// and the run cost an extra WaitDelay. A descendant that outlived the child
	// may also have appended its own writes to Out. The run logs one Warn for
	// it; a caller reads this field only to say so in its own error.
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

// CommandWithDelay is Command with a caller-chosen bound, for a test that pins
// the timeout-versus-delay race. A non-positive delay is clamped to
// DefaultWaitDelay: os/exec reads a zero WaitDelay as no bound at all, which is
// the wedge this package exists to prevent.
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

// Output runs the command and classifies the result. CombinedOutput is the
// same for cmd.CombinedOutput. Both return the bytes read either way, so a
// caller that wants partial output on failure still gets it.
//
// Error precedence is os/exec's: a non-zero exit or a failed wait always beats
// the WaitDelay overrun, so *exec.ExitError reaches callers keying on exit
// codes or Stderr exactly as before. A bare exec.ErrWaitDelay means the child
// itself exited successfully and only a descendant still held its pipes open;
// that is Result.Salvaged with a nil error, because discarding a complete
// result because an unrelated descendant is slow to exit is the worse failure.
// The salvage wins over the deadline: a child that finished inside the straddle
// window did not time out.
func (c *Cmd) Output() (Result, error) {
	out, err := c.cmd.Output()
	return c.report(classify(c.ctx, out, err))
}

// CombinedOutput runs the command under Output's classification.
func (c *Cmd) CombinedOutput() (Result, error) {
	out, err := c.cmd.CombinedOutput()
	return c.report(classify(c.ctx, out, err))
}

// report emits the one Warn a salvage is worth. Logging here rather than at the
// call site is what keeps it from being forgotten: without it the leaked
// descendant this package bounds, which also costs the request an extra
// WaitDelay, leaves no trace in production.
func (c *Cmd) report(res Result, err error) (Result, error) {
	if res.Salvaged {
		c.log.Warn("command exited but a descendant held its pipes open; output may include the descendant's writes",
			"tool", filepath.Base(c.cmd.Path))
	}
	return res, err
}

// Interrupted reports whether the context ended the run — its deadline or its
// cancellation — rather than the tool failing on its own.
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
	if ctxErr := ctx.Err(); ctxErr != nil {
		if errors.Is(ctxErr, context.DeadlineExceeded) {
			return res, fmt.Errorf("%w: %w", ErrTimeout, ctxErr)
		}
		return res, ctxErr
	}
	return res, err
}
