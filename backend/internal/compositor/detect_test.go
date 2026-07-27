package compositor

import (
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func resetDetector() {
	detectOnce = sync.Once{}
	detected = ""
}

func TestSocketIsLiveRejectsStaleUnixPath(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stale.sock")
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
	path := filepath.Join(t.TempDir(), "niri.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	t.Setenv("WAYLAND_DISPLAY", filepath.Join(t.TempDir(), "missing-wayland.sock"))
	t.Setenv("NIRI_SOCKET", path)
	t.Setenv("HYPRLAND_INSTANCE_SIGNATURE", "")
	resetDetector()
	t.Cleanup(resetDetector)
	if got := Current(); got != "niri" {
		t.Fatalf("Current() = %q, want niri", got)
	}
}

func TestCurrentIgnoresStaleNiriAndUsesLiveHyprland(t *testing.T) {
	runtimeDir := t.TempDir()
	signature := "test-instance"
	hyprPath := filepath.Join(runtimeDir, "hypr", signature, ".socket.sock")
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
