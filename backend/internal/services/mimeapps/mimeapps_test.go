package mimeapps

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeXdgMime(t *testing.T, body string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "xdg-mime")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func warnLogger() (*slog.Logger, *bytes.Buffer) {
	var buf bytes.Buffer
	return slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelWarn})), &buf
}

func TestMimeCommandTimeoutStaysBounded(t *testing.T) {
	if commandTimeout <= 0 || commandTimeout > 5*time.Second {
		t.Fatalf("commandTimeout = %v, want a bound in (0, 5s]", commandTimeout)
	}
}

func TestQueryDefaultTimesOutWithPipeHoldingDescendant(t *testing.T) {
	writeXdgMime(t, "sleep 6 &\nwait\n")

	started := time.Now()
	_, err := queryDefaultWithTimeout("text/plain", 50*time.Millisecond, nil)
	elapsed := time.Since(started)

	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("queryDefaultWithTimeout error = %v, want timeout", err)
	}
	if elapsed > 4*time.Second {
		t.Fatalf("queryDefaultWithTimeout took %v, want context deadline plus WaitDelay bound", elapsed)
	}
}

func TestQueryDefaultExitErrorMeansNoDefault(t *testing.T) {
	writeXdgMime(t, "exit 1\n")

	got, err := queryDefaultWithTimeout("text/plain", time.Second, nil)
	if err != nil {
		t.Fatalf("queryDefaultWithTimeout error = %v, want nil", err)
	}
	if got != "" {
		t.Fatalf("queryDefaultWithTimeout = %q, want empty default", got)
	}
}

func TestSetDefaultTimesOut(t *testing.T) {
	writeXdgMime(t, "exec sleep 60\n")

	started := time.Now()
	err := setDefaultWithTimeout("org.example.App.desktop", []string{"text/plain"}, 50*time.Millisecond, nil)
	elapsed := time.Since(started)

	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("setDefaultWithTimeout error = %v, want timeout", err)
	}
	if elapsed > time.Second {
		t.Fatalf("setDefaultWithTimeout took %v, want context deadline bound", elapsed)
	}
}

func TestQueryDefaultProductionPathTimesOut(t *testing.T) {
	writeXdgMime(t, "exec sleep 8\n")

	started := time.Now()
	_, err := queryDefault("text/plain", nil)
	elapsed := time.Since(started)

	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("queryDefault error = %v, want timeout", err)
	}
	if elapsed > 7*time.Second {
		t.Fatalf("queryDefault took %v, want production timeout bound", elapsed)
	}
}

func TestSetDefaultProductionPathTimesOut(t *testing.T) {
	writeXdgMime(t, "exec sleep 8\n")

	started := time.Now()
	err := setDefault("org.example.App.desktop", []string{"text/plain"}, nil)
	elapsed := time.Since(started)

	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("setDefault error = %v, want timeout", err)
	}
	if elapsed > 7*time.Second {
		t.Fatalf("setDefault took %v, want production timeout bound", elapsed)
	}
}

func TestSetDefaultMissingCommandNamesExecutable(t *testing.T) {
	t.Setenv("PATH", t.TempDir())

	err := setDefaultWithTimeout("org.example.App.desktop", []string{"text/plain"}, time.Second, nil)

	if err == nil {
		t.Fatal("setDefaultWithTimeout error = nil, want missing executable")
	}
	if !strings.Contains(err.Error(), "xdg-mime") || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("setDefaultWithTimeout error = %v, want missing executable named", err)
	}
}

func TestMimeHandlersPassServiceLoggerToProductionWrappers(t *testing.T) {
	writeXdgMime(t, "sleep 3 &\ncase \"$1\" in\nquery) printf 'org.example.App.desktop\\n' ;;\ndefault) ;;\n*) exit 2 ;;\nesac\n")
	log, buf := warnLogger()
	manager := &Manager{log: log}

	got, err := manager.handleGetDefault(json.RawMessage(`{"mimeType":"text/plain"}`))
	if err != nil {
		t.Fatalf("handleGetDefault error = %v, want nil", err)
	}
	result, ok := got.(map[string]any)
	if !ok {
		t.Fatalf("handleGetDefault result = %T, want map", got)
	}
	if result["desktopFileId"] != "org.example.App.desktop" {
		t.Fatalf("desktopFileId = %q, want desktop id", result["desktopFileId"])
	}
	_, err = manager.handleSetDefault(json.RawMessage(`{"mimeType":"text/plain","desktopFileId":"org.example.App.desktop"}`))
	if err != nil {
		t.Fatalf("handleSetDefault error = %v, want nil", err)
	}

	line := buf.String()
	if strings.Count(line, "level=WARN") != 2 {
		t.Fatalf("logged %q, want two salvage warnings", line)
	}
	if strings.Count(line, "tool=xdg-mime") != 2 {
		t.Fatalf("logged %q, want xdg-mime named twice", line)
	}
}
