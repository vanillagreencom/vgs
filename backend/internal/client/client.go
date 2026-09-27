// Package client sends diagnostic requests to the backend socket.
package client

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"vshell/backend/internal/protocol"
)

// SocketPath prefers VGS_BACKEND_SOCKET, then a live VGS_SOCKET. A stale
// inherited VGS_SOCKET falls back to session-file discovery in XDG_RUNTIME_DIR.
func SocketPath() (string, error) {
	if p := os.Getenv("VGS_BACKEND_SOCKET"); p != "" {
		return p, nil
	}
	env := os.Getenv("VGS_SOCKET")
	if env != "" && socketAlive(env) {
		return env, nil
	}
	if p := discoverSessionSocket(); p != "" {
		return p, nil
	}
	if env != "" {
		return env, nil // dead and undiscoverable: let dial report the real error
	}
	return "", fmt.Errorf("no backend socket: neither VGS_SOCKET nor VGS_BACKEND_SOCKET is set")
}

func socketAlive(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode()&os.ModeSocket != 0
}

// discoverSessionSocket finds the socket of a live `vshell run` via the
// vshell-<pid>.session files the runner writes to XDG_RUNTIME_DIR.
func discoverSessionSocket() string {
	runtimeDir := os.Getenv("XDG_RUNTIME_DIR")
	if runtimeDir == "" {
		return ""
	}
	entries, err := os.ReadDir(runtimeDir)
	if err != nil {
		return ""
	}
	for _, e := range entries {
		m := sessionPattern.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		pid, err := strconv.Atoi(m[1])
		if err != nil || syscall.Kill(pid, 0) != nil {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(runtimeDir, e.Name()))
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(raw), "\n") {
			if p, ok := strings.CutPrefix(line, "socket="); ok && socketAlive(strings.TrimSpace(p)) {
				return strings.TrimSpace(p)
			}
		}
	}
	return ""
}

var sessionPattern = regexp.MustCompile(`^vshell-(\d+)\.session$`)

// Request sends a single method call and returns the decoded response.
func Request(method string, params json.RawMessage) (*protocol.Response, error) {
	path, err := SocketPath()
	if err != nil {
		return nil, err
	}
	c, err := net.DialTimeout("unix", path, 3*time.Second)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", path, err)
	}
	defer c.Close()

	req := protocol.Request{ID: json.RawMessage("1"), Method: method, Params: params}
	b, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	if _, err := c.Write(append(b, '\n')); err != nil {
		return nil, err
	}

	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	sc := bufio.NewScanner(c)
	sc.Buffer(make([]byte, 0, 64<<10), 16<<20)
	if !sc.Scan() {
		if err := sc.Err(); err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("no response")
	}
	var resp protocol.Response
	if err := json.Unmarshal(sc.Bytes(), &resp); err != nil {
		return nil, err
	}
	return &resp, nil
}
