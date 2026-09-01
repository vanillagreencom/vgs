// Package execbound constructs one-shot external commands whose Wait cannot
// outlive the context indefinitely.
package execbound

import (
	"context"
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
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.WaitDelay = DefaultWaitDelay
	return cmd
}
