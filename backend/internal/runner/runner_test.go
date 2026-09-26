package runner

import (
	"errors"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"testing"
)

func TestClaimInstanceExportsRunnerPIDToChildren(t *testing.T) {
	t.Setenv(runnerPIDEnv, "")
	lock, err := claimInstance(t.TempDir(), slog.Default())
	if err != nil {
		t.Fatalf("claimInstance: %v", err)
	}
	defer lock.Close()

	want := runnerPIDEnv + "=" + strconv.Itoa(os.Getpid())
	// A Cmd with no Env set hands its child exactly this environment.
	if env := new(exec.Cmd).Environ(); !slices.Contains(env, want) {
		t.Fatalf("a child's environment lacks %q", want)
	}
}

func TestRunRefusedByHeldLockLeavesRuntimeFilesAlone(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	t.Setenv("VGS_BACKEND_SOCKET", "")
	t.Setenv(runnerPIDEnv, "")

	holder, err := acquireInstanceLock(dir, slog.Default())
	if err != nil {
		t.Fatalf("hold the lock: %v", err)
	}
	defer holder.Close()

	// removeStale unlinks this file once any socket setup runs: the offset pid is
	// assumed unused, as in TestRemoveStaleUnlinksDeadOnly.
	planted := filepath.Join(dir, "vshell-"+strconv.Itoa(os.Getpid()+1_000_000)+".sock")
	if err := os.WriteFile(planted, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}

	code, err := Run(Options{Log: slog.Default()})
	if !errors.Is(err, errInstanceRunning) || code != 1 {
		t.Fatalf("Run = (%d, %v), want (1, errInstanceRunning)", code, err)
	}
	if _, err := os.Stat(planted); err != nil {
		t.Errorf("a refused runner touched the runtime directory: %v", err)
	}
	if got := os.Getenv(runnerPIDEnv); got != "" {
		t.Errorf("a refused runner exported %s=%s", runnerPIDEnv, got)
	}
}

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
