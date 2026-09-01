package gamma

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"vshell/backend/internal/execbound"
)

const (
	hyprsunsetIPCAttempts       = 12
	hyprsunsetIPCAttemptTimeout = 500 * time.Millisecond
	hyprsunsetIPCRetryDelay     = 120 * time.Millisecond
)

// hyprsunsetIPC changes the running hyprsunset live over its hyprctl socket. It
// retries briefly because the socket is not connectable for a short window right
// after the process starts.
func (m *Manager) hyprsunsetIPC(args ...string) error {
	return m.hyprsunsetIPCWithBounds(hyprsunsetIPCAttemptTimeout, hyprsunsetIPCRetryDelay, args...)
}

func (m *Manager) hyprsunsetIPCWithBounds(timeout, retryDelay time.Duration, args ...string) error {
	full := append([]string{"hyprsunset"}, args...)
	var lastErr error
	for i := 0; i < hyprsunsetIPCAttempts; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		res, err := execbound.Command(ctx, m.hyprctl, full...).WithLogger(m.log).CombinedOutput()
		cancel()
		out := strings.TrimSpace(string(res.Out))
		if err == nil && !strings.Contains(out, "Couldn't connect") {
			return nil
		}
		if err != nil {
			if errors.Is(err, execbound.ErrTimeout) {
				lastErr = fmt.Errorf("hyprctl hyprsunset %v timed out", args)
			} else if out != "" {
				lastErr = fmt.Errorf("hyprctl hyprsunset %v: %w (%s)", args, err, out)
			} else {
				lastErr = fmt.Errorf("hyprctl hyprsunset %v: %w", args, err)
			}
		} else {
			lastErr = fmt.Errorf("hyprsunset socket not ready: %s", out)
		}
		if i < hyprsunsetIPCAttempts-1 && retryDelay > 0 {
			time.Sleep(retryDelay)
		}
	}
	return lastErr
}
