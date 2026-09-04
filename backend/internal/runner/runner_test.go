package runner

import (
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestRemoveStaleUnlinksDeadOnly(t *testing.T) {
	dir := t.TempDir()

	// The fixture assumes this offset PID is unused; it does not reserve or check
	// it.
	deadPID := os.Getpid() + 1_000_000
	livePID := os.Getpid()

	stale := filepath.Join(dir, "vshell-"+strconv.Itoa(deadPID)+".sock")
	stalePid := filepath.Join(dir, "vshell-"+strconv.Itoa(deadPID)+".pid")
	live := filepath.Join(dir, "vshell-"+strconv.Itoa(livePID)+".sock")
	unrelated := filepath.Join(dir, "something-else.sock")

	for _, p := range []string{stale, stalePid, live, unrelated} {
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	removeStale(dir, slog.Default())

	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Errorf("stale socket for dead pid should be removed")
	}
	if _, err := os.Stat(stalePid); !os.IsNotExist(err) {
		t.Errorf("stale pid file for dead pid should be removed")
	}
	if _, err := os.Stat(live); err != nil {
		t.Errorf("runtime file for live pid must be kept: %v", err)
	}
	if _, err := os.Stat(unrelated); err != nil {
		t.Errorf("unrelated file must be kept: %v", err)
	}
}

func TestSetupSocketFailsClosedWithoutRuntimeDir(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "")
	t.Setenv("VGS_BACKEND_SOCKET", "")
	st, err := setupSocket(slog.Default())
	if err == nil {
		st.teardown()
		t.Fatal("setupSocket must fail closed when XDG_RUNTIME_DIR is unset")
	}
}

func TestSetupSocketCreates0600(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	t.Setenv("VGS_BACKEND_SOCKET", "")

	st, err := setupSocket(slog.Default())
	if err != nil {
		t.Fatalf("setupSocket: %v", err)
	}
	defer st.teardown()

	fi, err := os.Stat(st.socketPath)
	if err != nil {
		t.Fatalf("stat socket: %v", err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("socket perms = %o, want 0600", perm)
	}

	st.teardown()
	st2, err := setupSocket(slog.Default())
	if err != nil {
		t.Fatalf("setupSocket after stale socket left in place: %v", err)
	}
	st2.teardown()
}
