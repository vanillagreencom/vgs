package mimeapps

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os/exec"
	"strings"
	"time"

	"vshell/backend/internal/execbound"
)

const commandTimeout = 5 * time.Second

func queryDefault(mimeType string, log *slog.Logger) (string, error) {
	return queryDefaultWithTimeout(mimeType, commandTimeout, log)
}

func queryDefaultWithTimeout(mimeType string, timeout time.Duration, log *slog.Logger) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	res, err := execbound.Command(ctx, "xdg-mime", "query", "default", mimeType).WithLogger(log).Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return "", nil
		}
		if errors.Is(err, execbound.ErrTimeout) {
			return "", fmt.Errorf("xdg-mime query default timed out")
		}
		return "", err
	}
	return strings.TrimSpace(string(res.Out)), nil
}

func setDefault(desktopID string, mimeTypes []string, log *slog.Logger) error {
	return setDefaultWithTimeout(desktopID, mimeTypes, commandTimeout, log)
}

func setDefaultWithTimeout(desktopID string, mimeTypes []string, timeout time.Duration, log *slog.Logger) error {
	args := append([]string{"default", desktopID}, mimeTypes...)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	res, err := execbound.Command(ctx, "xdg-mime", args...).WithLogger(log).CombinedOutput()
	if err != nil {
		if errors.Is(err, execbound.ErrTimeout) {
			return fmt.Errorf("xdg-mime default timed out")
		}
		msg := strings.TrimSpace(string(res.Out))
		if msg != "" {
			return fmt.Errorf("xdg-mime default failed: %s", msg)
		}
		return fmt.Errorf("xdg-mime default failed: %w", err)
	}
	return nil
}
