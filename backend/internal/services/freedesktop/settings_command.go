package freedesktop

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"vshell/backend/internal/execbound"
)

const settingsCommandTimeout = 5 * time.Second

func setIconTheme(command, theme string, timeout time.Duration, log *slog.Logger) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	res, err := execbound.Command(ctx, command, "set", "org.gnome.desktop.interface", "icon-theme", theme).WithLogger(log).CombinedOutput()
	if err == nil {
		return nil
	}
	if errors.Is(err, execbound.ErrTimeout) {
		return fmt.Errorf("gsettings set icon-theme timed out")
	}
	msg := strings.TrimSpace(string(res.Out))
	if msg != "" {
		return fmt.Errorf("set icon theme: %s", msg)
	}
	return fmt.Errorf("set icon theme: %w", err)
}
