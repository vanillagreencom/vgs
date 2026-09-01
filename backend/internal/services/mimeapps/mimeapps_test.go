package mimeapps

import (
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

func TestQueryDefaultTimesOutWithPipeHoldingDescendant(t *testing.T) {
	writeXdgMime(t, "sleep 6 &\nwait\n")

	started := time.Now()
	_, err := queryDefaultWithTimeout("text/plain", 50*time.Millisecond)
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

	got, err := queryDefaultWithTimeout("text/plain", time.Second)
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
	err := setDefaultWithTimeout("org.example.App.desktop", []string{"text/plain"}, 50*time.Millisecond)
	elapsed := time.Since(started)

	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("setDefaultWithTimeout error = %v, want timeout", err)
	}
	if elapsed > time.Second {
		t.Fatalf("setDefaultWithTimeout took %v, want context deadline bound", elapsed)
	}
}
