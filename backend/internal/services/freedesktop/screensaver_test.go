package freedesktop

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeGSettings(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "gsettings")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestSetIconThemeTimesOutWithPipeHoldingDescendant(t *testing.T) {
	command := writeGSettings(t, "sleep 6 &\nwait\n")

	started := time.Now()
	err := setIconTheme(command, "Adwaita", 50*time.Millisecond, nil)
	elapsed := time.Since(started)

	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("setIconTheme error = %v, want timeout", err)
	}
	if elapsed > 4*time.Second {
		t.Fatalf("setIconTheme took %v, want context deadline plus WaitDelay bound", elapsed)
	}
}
