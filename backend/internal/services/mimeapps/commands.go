package mimeapps

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"vshell/backend/internal/execbound"
)

const commandTimeout = 5 * time.Second

func queryDefault(mimeType string) (string, error) {
	return queryDefaultWithTimeout(mimeType, commandTimeout)
}

func queryDefaultWithTimeout(mimeType string, timeout time.Duration) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	res, err := execbound.Command(ctx, "xdg-mime", "query", "default", mimeType).Output()
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

func setDefault(desktopID string, mimeTypes []string) error {
	return setDefaultWithTimeout(desktopID, mimeTypes, commandTimeout)
}

func setDefaultWithTimeout(desktopID string, mimeTypes []string, timeout time.Duration) error {
	args := append([]string{"default", desktopID}, mimeTypes...)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	res, err := execbound.Command(ctx, "xdg-mime", args...).CombinedOutput()
	if err != nil {
		if errors.Is(err, execbound.ErrTimeout) {
			return fmt.Errorf("xdg-mime default timed out")
		}
		return fmt.Errorf("xdg-mime default failed: %s", strings.TrimSpace(string(res.Out)))
	}
	return nil
}
