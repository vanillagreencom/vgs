package runner

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// instanceLockName is the session's single-instance lock under XDG_RUNTIME_DIR.
const instanceLockName = "vshell.lock"

// runnerPIDEnv names the runner holding the instance lock. shell.qml starts only
// when this pid is its own parent.
const runnerPIDEnv = "VGS_RUNNER_PID"

// errInstanceRunning reports that another runner holds the instance lock.
var errInstanceRunning = errors.New("instance lock held by another VGS runner")

// acquireInstanceLock takes an exclusive non-blocking flock on
// $XDG_RUNTIME_DIR/vshell.lock and records this runner's pid in it. The caller
// keeps the returned file open for its whole life; the kernel drops the lock when
// the runner exits by any means. Go opens the file close-on-exec, so no child
// keeps the lock after the runner is gone.
func acquireInstanceLock(runtimeDir string, log *slog.Logger) (*os.File, error) {
	if runtimeDir == "" {
		return nil, fmt.Errorf("XDG_RUNTIME_DIR is not set; refusing to start without the instance lock")
	}
	path := filepath.Join(runtimeDir, instanceLockName)
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open instance lock %s: %w", path, err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, fmt.Errorf("%w: %s (runner pid %s)", errInstanceRunning, path, lockHolder(path))
		}
		return nil, fmt.Errorf("lock %s: %w", path, err)
	}
	// The pid only names the holder in a refusal; the lock itself is the guard.
	if err := f.Truncate(0); err != nil {
		log.Warn("instance lock holder pid not recorded", "path", path, "err", err)
	} else if _, err := f.WriteAt([]byte(strconv.Itoa(os.Getpid())+"\n"), 0); err != nil {
		log.Warn("instance lock holder pid not recorded", "path", path, "err", err)
	}
	return f, nil
}

func lockHolder(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return "unknown: " + err.Error()
	}
	if pid := strings.TrimSpace(string(data)); pid != "" {
		return pid
	}
	return "unknown"
}
