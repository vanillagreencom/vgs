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

// A gsettings that never returns must end as a timeout within a bound: the
// injected path with a pipe-holding descendant, and the production handler
// with its own default timeout.
func TestIconThemeCommandsTimeOut(t *testing.T) {
	// The production row also has a floor: a zero timeout would report a
	// timeout at once and make every icon-theme change fail.
	cases := []struct {
		name   string
		script string
		floor  time.Duration
		bound  time.Duration
		call   func(command string) error
	}{
		{"setIconTheme with a pipe-holding descendant", "sleep 6 &\nwait\n", 0, 4 * time.Second, func(command string) error {
			return setIconTheme(command, "Adwaita", 50*time.Millisecond, nil)
		}},
		{"handleSetIconTheme on the production path", "exec sleep 8\n", time.Second, 7 * time.Second, func(command string) error {
			t.Setenv("PATH", filepath.Dir(command)+string(os.PathListSeparator)+os.Getenv("PATH"))
			_, err := (&Manager{}).handleSetIconTheme(json.RawMessage(`{"iconTheme":"Adwaita"}`))
			return err
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			command := writeGSettings(t, tc.script)
			started := time.Now()
			err := tc.call(command)
			elapsed := time.Since(started)
			if err == nil || !strings.Contains(err.Error(), "timed out") {
				t.Fatalf("error = %v, want timeout", err)
			}
			if elapsed < tc.floor || elapsed > tc.bound {
				t.Fatalf("took %v, want between %v and %v", elapsed, tc.floor, tc.bound)
			}
		})
	}
}
