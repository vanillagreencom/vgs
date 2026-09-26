package compositor

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func resetDetector() {
	detectOnce = sync.Once{}
	detected = ""
}

// socketPathMax is the kernel's cap on a Unix socket path. sun_path is a fixed
// 108-byte array, so bind() answers EINVAL for anything longer.
const socketPathMax = 108

// socketDir returns a directory with room for leaf inside that cap.
//
// t.TempDir() is the usual choice and the wrong one for a socket: it names the
// directory after the calling test, so a 45-character test name plus a nested
// runtime path spends most of the budget before $TMPDIR is counted at all. A
// long TMPDIR then overflows it — this package's own agent runs bind at 124
// bytes and fail, while a /tmp base lands at 96 and passes, which is a
// difference in environment rather than in the code under test.
//
// Prefer the configured temporary directory and fall back to /tmp only when it
// genuinely cannot fit, so a deliberate TMPDIR is honoured wherever the limit
// allows. The path is measured rather than estimated, because the random suffix
// os.MkdirTemp appends is part of the budget.
func socketDir(t *testing.T, leaf string) string {
	t.Helper()
	bases := []string{os.TempDir()}
	if os.TempDir() != "/tmp" {
		bases = append(bases, "/tmp")
	}
	for _, base := range bases {
		// Only a measured over-limit path may reach the fallback. A base that
		// cannot be created is an environment fault, and skipping it here would
		// quietly ignore a deliberately configured TMPDIR and then blame the
		// sun_path limit below for a failure that was never about length.
		dir, err := os.MkdirTemp(base, "vgs")
		if err != nil {
			t.Fatalf("creating a socket directory under %s: %v", base, err)
		}
		if len(filepath.Join(dir, leaf)) < socketPathMax {
			t.Cleanup(func() {
				if err := os.RemoveAll(dir); err != nil {
					t.Errorf("removing the socket directory %s: %v", dir, err)
				}
			})
			return dir
		}
		if err := os.RemoveAll(dir); err != nil {
			t.Errorf("removing the socket directory %s: %v", dir, err)
		}
	}
	t.Fatalf("no temporary directory leaves room for %q within the %d-byte sun_path limit (tried %v)", leaf, socketPathMax, bases)
	return ""
}

// TestSocketDirPrefersConfiguredTempAndFallsBack drives both socketDir arms on
// purpose. The three detection tests below only ever see the runner's ambient
// TMPDIR — /tmp on CI, which fits — so none of them would fail if the fallback
// were dropped and long-TMPDIR machines started failing with EINVAL again.
func TestSocketDirPrefersConfiguredTempAndFallsBack(t *testing.T) {
	leaf := filepath.Join("hypr", "test-instance", ".socket.sock")

	// A short base, so socketDir's measurement leaves room for leaf.
	fitting, err := os.MkdirTemp("/tmp", "vgsfit")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(fitting); err != nil {
			t.Errorf("removing %s: %v", fitting, err)
		}
	})

	// A base long enough that any directory under it overflows sun_path.
	overlimit := filepath.Join("/tmp", "vgsover0123456", "aaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbb", "ccccccccccccccc", "ddddddddddddddd")
	if err := os.MkdirAll(overlimit, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(filepath.Join("/tmp", "vgsover0123456")); err != nil {
			t.Errorf("removing %s: %v", overlimit, err)
		}
	})
	if len(filepath.Join(overlimit, "vgs000000000", leaf)) < socketPathMax {
		t.Fatalf("fixture base %q is not over the %d-byte limit; the fallback arm would not be driven", overlimit, socketPathMax)
	}

	t.Run("prefers the configured temporary directory", func(t *testing.T) {
		t.Setenv("TMPDIR", fitting)
		dir := socketDir(t, leaf)
		if !strings.HasPrefix(dir, fitting+string(os.PathSeparator)) {
			t.Fatalf("socketDir() = %q, want a directory under the configured TMPDIR %q", dir, fitting)
		}
		mustBind(t, dir, leaf)
	})

	t.Run("falls back when the configured directory cannot fit", func(t *testing.T) {
		t.Setenv("TMPDIR", overlimit)
		dir := socketDir(t, leaf)
		if strings.HasPrefix(dir, overlimit+string(os.PathSeparator)) {
			t.Fatalf("socketDir() = %q, want the /tmp fallback rather than the over-limit TMPDIR", dir)
		}
		mustBind(t, dir, leaf)
	})
}

// mustBind proves the chosen directory can carry a real socket, so a base that
// merely measures short still has to work.
func mustBind(t *testing.T, dir, leaf string) {
	t.Helper()
	path := filepath.Join(dir, leaf)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("binding %d-byte path %s: %v", len(path), path, err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestSocketIsLiveRejectsStaleUnixPath(t *testing.T) {
	path := filepath.Join(socketDir(t, "stale.sock"), "stale.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	if socketIsLive(path) {
		t.Fatal("stale Unix socket path reported live")
	}
}

func TestCurrentUsesLiveNiriFallback(t *testing.T) {
	dir := socketDir(t, "niri.sock")
	path := filepath.Join(dir, "niri.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	t.Setenv("WAYLAND_DISPLAY", filepath.Join(dir, "missing-wayland.sock"))
	t.Setenv("NIRI_SOCKET", path)
	t.Setenv("HYPRLAND_INSTANCE_SIGNATURE", "")
	resetDetector()
	t.Cleanup(resetDetector)
	if got := Current(); got != "niri" {
		t.Fatalf("Current() = %q, want niri", got)
	}
}

func TestCurrentIgnoresStaleNiriAndUsesLiveHyprland(t *testing.T) {
	signature := "test-instance"
	socketLeaf := filepath.Join("hypr", signature, ".socket.sock")
	runtimeDir := socketDir(t, socketLeaf)
	hyprPath := filepath.Join(runtimeDir, socketLeaf)
	if err := os.MkdirAll(filepath.Dir(hyprPath), 0o755); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", hyprPath)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	t.Setenv("WAYLAND_DISPLAY", filepath.Join(runtimeDir, "missing-wayland.sock"))
	t.Setenv("XDG_RUNTIME_DIR", runtimeDir)
	t.Setenv("NIRI_SOCKET", filepath.Join(runtimeDir, "stale-niri.sock"))
	t.Setenv("HYPRLAND_INSTANCE_SIGNATURE", signature)
	resetDetector()
	t.Cleanup(resetDetector)
	if got := Current(); got != "hyprland" {
		t.Fatalf("Current() = %q, want hyprland", got)
	}
}
