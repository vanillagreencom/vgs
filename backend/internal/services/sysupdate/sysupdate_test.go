package sysupdate

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"vshell/backend/internal/server"
)

func TestParseCheckupdates(t *testing.T) {
	packages := parseCheckupdates([]byte("go 2:1.26.4-2 -> 2:1.26.5-2\n"))
	if len(packages) != 1 {
		t.Fatalf("len(packages) = %d, want 1", len(packages))
	}
	pkg := packages[0]
	if pkg.Name != "go" || pkg.Repo != "system" || pkg.Backend != "pacman" || pkg.FromVersion != "2:1.26.4-2" || pkg.ToVersion != "2:1.26.5-2" {
		t.Fatalf("unexpected package: %#v", pkg)
	}
}

func TestParseParu(t *testing.T) {
	packages := parseParu([]byte("openai-codex-bin 0.142.5-1 -> 0.143.0-1\n"))
	if len(packages) != 1 {
		t.Fatalf("len(packages) = %d, want 1", len(packages))
	}
	pkg := packages[0]
	if pkg.Name != "openai-codex-bin" || pkg.Repo != "aur" || pkg.Backend != "paru" || pkg.FromVersion != "0.142.5-1" || pkg.ToVersion != "0.143.0-1" {
		t.Fatalf("unexpected package: %#v", pkg)
	}
}

func TestUpgradeCommandModes(t *testing.T) {
	m := &Manager{paru: "/usr/bin/paru", pacman: "/usr/bin/pacman"}
	if got := m.upgradeCommand(upgradeParams{Mode: "system"}); got == "" || contains(got, "paru") {
		t.Fatalf("system command = %q, want pacman-only command", got)
	}
	if got := m.upgradeCommand(upgradeParams{Mode: "aur"}); got == "" || !contains(got, "-Sua") {
		t.Fatalf("aur command = %q, want paru -Sua command", got)
	}
	if got := m.upgradeCommand(upgradeParams{Mode: "all", IncludeAUR: true}); got == "" || !contains(got, "pacman") || !contains(got, "-Sua") || contains(got, "paru' -Syu") {
		t.Fatalf("all command = %q, want repo-only pacman followed by AUR-only paru", got)
	}
}

func TestTerminalArgvKeepsShellCommandPosition(t *testing.T) {
	m := &Manager{uwsm: "/usr/bin/uwsm", terminalExec: "/usr/bin/xdg-terminal-exec"}
	argv, err := m.terminalArgv("", "printf harmless")
	if err != nil {
		t.Fatal(err)
	}
	if len(argv) < 4 || argv[len(argv)-4] != "sh" || argv[len(argv)-3] != "-lc" || argv[len(argv)-2] != "printf harmless" || argv[len(argv)-1] != "vshell-update" {
		t.Fatalf("terminal argv tail = %#v, want sh -lc <command> <argv0>", argv)
	}
}

func TestAcquireReleaseSchedulesRefresh(t *testing.T) {
	m := &Manager{srv: server.New(0, nil)}
	m.state = State{Phase: "idle", IntervalSeconds: 60, RecentLog: []string{}}
	t.Cleanup(m.Close)

	resp, err := m.handleAcquire(nil)
	if err != nil {
		t.Fatal(err)
	}
	state := resp.(State)
	if state.NextCheckUnix <= time.Now().Unix() {
		t.Fatalf("NextCheckUnix = %d, want future schedule", state.NextCheckUnix)
	}

	resp, err = m.handleRelease(nil)
	if err != nil {
		t.Fatal(err)
	}
	state = resp.(State)
	if state.NextCheckUnix != 0 {
		t.Fatalf("NextCheckUnix after release = %d, want 0", state.NextCheckUnix)
	}
}

func TestSetIntervalReschedulesOnlyWhenAcquired(t *testing.T) {
	m := &Manager{srv: server.New(0, nil)}
	m.state = State{Phase: "idle", IntervalSeconds: 60, LastCheckUnix: time.Now().Unix(), RecentLog: []string{}}
	t.Cleanup(m.Close)

	resp, err := m.handleSetInterval(mustJSON(t, intervalParams{Seconds: 30}))
	if err != nil {
		t.Fatal(err)
	}
	if got := resp.(State).NextCheckUnix; got != 0 {
		t.Fatalf("NextCheckUnix without acquire = %d, want 0", got)
	}

	if _, err := m.handleAcquire(nil); err != nil {
		t.Fatal(err)
	}
	resp, err = m.handleSetInterval(mustJSON(t, intervalParams{Seconds: 45}))
	if err != nil {
		t.Fatal(err)
	}
	if got := resp.(State).NextCheckUnix; got <= time.Now().Unix() {
		t.Fatalf("NextCheckUnix after acquire = %d, want future schedule", got)
	}
}

func TestCommandOutputPropagatesUnexpectedEmptyFailure(t *testing.T) {
	_, err := commandOutput(testContext(t), false, "sh", "-c", "exit 1")
	if err == nil {
		t.Fatal("commandOutput returned nil error for unexpected empty failure")
	}

	_, err = commandOutput(testContext(t), true, "sh", "-c", "exit 2")
	if err != nil {
		t.Fatalf("commandOutput with checkupdates no-update exit returned %v", err)
	}
}

func TestScheduledRefreshRunsAndReschedules(t *testing.T) {
	cmd, logPath := fakeUpdateCommand(t, "go 2:1.26.4-2 -> 2:1.26.5-2\n", 0)
	m := &Manager{srv: server.New(0, nil), checkupdates: cmd}
	m.state = State{Phase: "idle", Backends: m.backends(), IntervalSeconds: 1, RecentLog: []string{}}
	t.Cleanup(m.Close)

	if _, err := m.handleAcquire(nil); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool {
		state := m.snapshot().(State)
		return state.Count == 1 && state.LastSuccessUnix > 0 && state.NextCheckUnix > state.LastCheckUnix
	})
	if calls := readFile(t, logPath); calls == "" {
		t.Fatal("scheduled refresh did not run fake command")
	}
}

func TestScheduledRefreshStopsOnReleaseAndClose(t *testing.T) {
	cmd, logPath := fakeUpdateCommand(t, "", 0)
	m := &Manager{srv: server.New(0, nil), checkupdates: cmd}
	m.state = State{Phase: "idle", Backends: m.backends(), IntervalSeconds: 1, RecentLog: []string{}}

	if _, err := m.handleAcquire(nil); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handleRelease(nil); err != nil {
		t.Fatal(err)
	}
	time.Sleep(1200 * time.Millisecond)
	if calls := readFile(t, logPath); calls != "" {
		t.Fatalf("scheduled refresh ran after release:\n%s", calls)
	}
	if state := m.snapshot().(State); state.NextCheckUnix != 0 {
		t.Fatalf("NextCheckUnix after release = %d, want 0", state.NextCheckUnix)
	}

	if _, err := m.handleAcquire(nil); err != nil {
		t.Fatal(err)
	}
	m.Close()
	time.Sleep(1200 * time.Millisecond)
	if calls := readFile(t, logPath); calls != "" {
		t.Fatalf("scheduled refresh ran after close:\n%s", calls)
	}
}

func TestUpgradePrelaunchFailureSetsStateError(t *testing.T) {
	m := &Manager{srv: server.New(0, nil)}
	m.state = State{Phase: "idle", IntervalSeconds: 60, RecentLog: []string{}}

	resp, err := m.handleUpgrade(mustJSON(t, upgradeParams{Mode: "system"}))
	if err == nil || resp != nil {
		t.Fatalf("handleUpgrade = (%#v, %v), want nil error", resp, err)
	}
	state := m.snapshot().(State)
	if state.Phase != "idle" || state.OperationID != "" || state.OperationStartedUnix != 0 {
		t.Fatalf("state left busy: %#v", state)
	}
	if state.Error == nil || state.Error.Code != "upgrade_unavailable" || state.Error.Message == "" {
		t.Fatalf("missing upgrade error: %#v", state.Error)
	}
	if len(state.RecentLog) == 0 || !contains(state.RecentLog[len(state.RecentLog)-1], "no supported upgrade command") {
		t.Fatalf("missing recent log entry: %#v", state.RecentLog)
	}
}

func mustJSON(t *testing.T, value any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	t.Cleanup(cancel)
	return ctx
}

func fakeUpdateCommand(t *testing.T, stdout string, code int) (string, string) {
	t.Helper()
	dir := t.TempDir()
	logPath := filepath.Join(dir, "calls.log")
	path := filepath.Join(dir, "checkupdates")
	body := "#!/bin/sh\n" +
		"printf 'called\\n' >> '" + logPath + "'\n" +
		"printf '%s' '" + stdout + "'\n" +
		"exit " + strconv.Itoa(code) + "\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path, logPath
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return ""
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func waitFor(t *testing.T, fn func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if fn() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("condition was not met before timeout")
}

func contains(value, needle string) bool {
	for i := 0; i+len(needle) <= len(value); i++ {
		if value[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}
