package freedesktop

import (
	"encoding/json"
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

func TestSettingsCommandTimeoutStaysBounded(t *testing.T) {
	if settingsCommandTimeout <= 0 || settingsCommandTimeout > 5*time.Second {
		t.Fatalf("settingsCommandTimeout = %v, want a bound in (0, 5s]", settingsCommandTimeout)
	}
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

func TestHandleSetIconThemeProductionPathTimesOut(t *testing.T) {
	command := writeGSettings(t, "exec sleep 8\n")
	t.Setenv("PATH", filepath.Dir(command)+string(os.PathListSeparator)+os.Getenv("PATH"))
	manager := &Manager{}

	started := time.Now()
	_, err := manager.handleSetIconTheme(json.RawMessage(`{"iconTheme":"Adwaita"}`))
	elapsed := time.Since(started)

	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("handleSetIconTheme error = %v, want timeout", err)
	}
	if elapsed > 7*time.Second {
		t.Fatalf("handleSetIconTheme took %v, want production timeout bound", elapsed)
	}
}
