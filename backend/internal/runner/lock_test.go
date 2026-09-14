package runner

import (
	"errors"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"testing"
)

func TestInstanceLockAdmitsOneRunner(t *testing.T) {
	dir := t.TempDir()
	first, err := acquireInstanceLock(dir, slog.Default())
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}

	// flock binds to the open file description, so a second open in this process
	// contends exactly as a second runner process would.
	second, err := acquireInstanceLock(dir, slog.Default())
	if !errors.Is(err, errInstanceRunning) {
		if second != nil {
			second.Close()
		}
		first.Close()
		t.Fatalf("second acquire err = %v, want errInstanceRunning", err)
	}
	if want := "runner pid " + strconv.Itoa(os.Getpid()); !strings.Contains(err.Error(), want) {
		t.Errorf("refusal %q does not contain %q", err, want)
	}

	first.Close()
	third, err := acquireInstanceLock(dir, slog.Default())
	if err != nil {
		t.Fatalf("acquire after the holder closed the lock: %v", err)
	}
	third.Close()
}

func TestInstanceLockRequiresRuntimeDir(t *testing.T) {
	f, err := acquireInstanceLock("", slog.Default())
	if err == nil {
		f.Close()
		t.Fatal("acquireInstanceLock must refuse when XDG_RUNTIME_DIR is unset")
	}
	if errors.Is(err, errInstanceRunning) {
		t.Fatalf("an unset runtime dir reported a running instance: %v", err)
	}
}
