// Package compositor resolves the compositor that owns the Wayland socket used
// by this process. Session environment variables are liveness-checked fallbacks
// because systemd may retain stale values across compositor changes.
package compositor

import (
	"bufio"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	detectOnce sync.Once
	detected   string
)

func Current() string {
	detectOnce.Do(func() {
		detected = socketOwner()
		if detected != "" {
			return
		}
		if socketIsLive(os.Getenv("NIRI_SOCKET")) {
			detected = "niri"
			return
		}
		runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
		signature := os.Getenv("HYPRLAND_INSTANCE_SIGNATURE")
		if runtimeDir != "" && signature != "" &&
			socketIsLive(filepath.Join(runtimeDir, "hypr", signature, ".socket.sock")) {
			detected = "hyprland"
		}
	})
	return detected
}

func socketOwner() string {
	socket := os.Getenv("WAYLAND_DISPLAY")
	if socket == "" {
		socket = "wayland-0"
	}
	if !filepath.IsAbs(socket) {
		runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
		if runtimeDir == "" {
			runtimeDir = "/run/user/" + strconv.Itoa(os.Getuid())
		}
		socket = filepath.Join(runtimeDir, socket)
	}
	file, err := os.Open("/proc/net/unix")
	if err != nil {
		return ""
	}
	defer file.Close()
	inode := ""
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) >= 8 && fields[len(fields)-1] == socket {
			inode = fields[6]
			break
		}
	}
	if inode == "" {
		return ""
	}
	target := "socket:[" + inode + "]"
	processes, _ := filepath.Glob("/proc/[0-9]*")
	for _, process := range processes {
		fds, _ := filepath.Glob(filepath.Join(process, "fd", "*"))
		for _, fd := range fds {
			link, err := os.Readlink(fd)
			if err != nil || link != target {
				continue
			}
			name, err := os.ReadFile(filepath.Join(process, "comm"))
			if err != nil {
				continue
			}
			switch strings.ToLower(strings.TrimSpace(string(name))) {
			case "niri":
				return "niri"
			case "hyprland":
				return "hyprland"
			}
		}
	}
	return ""
}

func socketIsLive(path string) bool {
	info, err := os.Stat(path)
	if path == "" || err != nil || info.Mode()&os.ModeSocket == 0 {
		return false
	}
	connection, err := net.DialTimeout("unix", path, 250*time.Millisecond)
	if err != nil {
		return false
	}
	_ = connection.Close()
	return true
}
