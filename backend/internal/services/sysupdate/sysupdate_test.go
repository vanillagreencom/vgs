package sysupdate

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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

// The mode is validated against the updaters actually present, so a
// "tools" upgrade on a machine without mise fails before a terminal opens
// rather than running a step that prints "mise not found" and exits.
func TestUpgradeModeRequiresItsUpdater(t *testing.T) {
	m := &Manager{vshell: "/usr/bin/vshell", paru: "/usr/bin/paru", pacman: "/usr/bin/pacman", checkupdates: "/usr/bin/checkupdates"}
	for _, mode := range []string{"system", "aur", "all", ""} {
		if _, err := m.upgradeMode(mode); err != nil {
			t.Fatalf("upgradeMode(%q) = %v, want ok", mode, err)
		}
	}
	for _, mode := range []string{"tools", "flatpak", "bogus"} {
		if got, err := m.upgradeMode(mode); err == nil {
			t.Fatalf("upgradeMode(%q) = %q, want error", mode, got)
		}
	}
	if got, _ := m.upgradeMode(""); got != "all" {
		t.Fatalf("upgradeMode(\"\") = %q, want all", got)
	}
	withMise := &Manager{vshell: "/usr/bin/vshell", mise: "/usr/bin/mise"}
	if got, err := withMise.upgradeMode("tools"); err != nil || got != "tools" {
		t.Fatalf("upgradeMode(tools) with mise = (%q, %v), want tools", got, err)
	}
	if _, err := (&Manager{pacman: "/usr/bin/pacman", checkupdates: "/usr/bin/checkupdates"}).upgradeMode("system"); err == nil {
		t.Fatal("upgradeMode without the vshell CLI must fail: the terminal runs `vshell update run`")
	}
	// The widget shows a system button only when the backend advertises one;
	// pacman without checkupdates advertises none and must not upgrade either.
	if _, err := (&Manager{vshell: "/usr/bin/vshell", pacman: "/usr/bin/pacman"}).upgradeMode("system"); err == nil {
		t.Fatal("upgradeMode(system) without checkupdates must fail: backends() advertises no system backend")
	}
}

// The CLI owns the per-source commands; the daemon hands it the mode and
// nothing else, so there is exactly one spelling of "how to upgrade".
func TestTerminalArgvRunsTheCLIUpdater(t *testing.T) {
	m := &Manager{vshell: "/usr/bin/vshell"}
	argv, err := m.terminalArgv("", "tools")
	if err != nil {
		t.Fatal(err)
	}
	if len(argv) < 5 || argv[len(argv)-5] != "--" || argv[len(argv)-4] != "/usr/bin/vshell" || argv[len(argv)-3] != "update" || argv[len(argv)-2] != "run" || argv[len(argv)-1] != "tools" {
		t.Fatalf("terminal argv tail = %#v, want -- vshell update run tools", argv)
	}
	if _, err := (&Manager{}).terminalArgv("", "all"); err == nil {
		t.Fatal("terminalArgv without the vshell CLI must fail")
	}
}

func TestParseMiseOutdated(t *testing.T) {
	packages, err := parseMiseOutdated([]byte(`{"npm:@deepseek-ai/dsh": {"name": "npm:@deepseek-ai/dsh", "requested": "latest", "current": "0.1.0", "latest": "0.1.1"}, "claude": {"name": "claude", "requested": "latest", "current": "2.1.0", "latest": "2.2.0"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(packages) != 2 {
		t.Fatalf("len(packages) = %d, want 2", len(packages))
	}
	if packages[0].Name != "claude" || packages[0].Repo != "tools" || packages[0].Backend != "mise" || packages[0].FromVersion != "2.1.0" || packages[0].ToVersion != "2.2.0" {
		t.Fatalf("unexpected package: %#v", packages[0])
	}
	if packages[1].Name != "npm:@deepseek-ai/dsh" {
		t.Fatalf("packages must be sorted by name: %#v", packages)
	}
	if up, err := parseMiseOutdated([]byte("{}\n")); err != nil || len(up) != 0 {
		t.Fatalf("up to date = (%#v, %v), want empty", up, err)
	}
	if _, err := parseMiseOutdated([]byte("mise ERROR nope")); err == nil {
		t.Fatal("non-JSON output must be an error, not zero updates")
	}
	if _, err := parseMiseOutdated([]byte("  \n")); err == nil {
		t.Fatal("empty output must be an error: up to date prints {}")
	}
}

func TestBackendsListsMise(t *testing.T) {
	m := &Manager{mise: "/usr/bin/mise"}
	backends := m.backends()
	if len(backends) != 1 || backends[0].ID != "mise" || backends[0].Repo != "tools" || backends[0].NeedsAuth {
		t.Fatalf("backends = %#v, want one mise/tools backend without auth", backends)
	}
}

// waitUpgrade treats the launched process exiting as the upgrade finishing, so
// the helper must be told to stay alive for the terminal's whole lifetime.
// Without this the phase returns to idle while pacman is still running and a
// second upgrade can be started on top of it.
func TestTerminalArgvWaitsForTheUpgradeToFinish(t *testing.T) {
	m := &Manager{vshell: "/usr/bin/vshell"}
	argv, err := m.terminalArgv("", "all")
	if err != nil {
		t.Fatal(err)
	}
	if !contains(strings.Join(argv, " "), "--wait") {
		t.Fatalf("terminal argv = %#v, want --wait", argv)
	}
}

// An explicit terminal from upgradeParams must reach the resolver rather than
// being dropped because the CLI happens to be on PATH.
func TestTerminalArgvForwardsTheCallersTerminal(t *testing.T) {
	m := &Manager{vshell: "/usr/bin/vshell"}
	argv, err := m.terminalArgv("foot", "all")
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for i, arg := range argv {
		if arg == "--prefer" && i+1 < len(argv) && argv[i+1] == "foot" {
			found = true
		}
		if arg == "--" {
			break
		}
	}
	if !found {
		t.Fatalf("terminal argv = %#v, want --prefer foot before --", argv)
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
	_, err := commandOutput(testContext(t), nil, false, "sh", "-c", "exit 1")
	if err == nil {
		t.Fatal("commandOutput returned nil error for unexpected empty failure")
	}

	_, err = commandOutput(testContext(t), nil, true, "sh", "-c", "exit 2")
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
	if len(state.RecentLog) == 0 || !contains(state.RecentLog[len(state.RecentLog)-1], "vshell CLI not found") {
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

// Recount after a failed upgrade because completed steps can still change the
// installed packages.
func TestUpgradeRecountsAfterAnyExit(t *testing.T) {
	for _, code := range []int{0, 1} {
		counter, logPath := fakeUpdateCommand(t, "go 2:1.26.4-2 -> 2:1.26.5-2\n", 0)
		dir := t.TempDir()
		vshell := filepath.Join(dir, "vshell")
		if err := os.WriteFile(vshell, []byte("#!/bin/sh\nexit "+strconv.Itoa(code)+"\n"), 0o755); err != nil {
			t.Fatal(err)
		}
		m := &Manager{srv: server.New(0, nil), checkupdates: counter, pacman: "/usr/bin/pacman", vshell: vshell}
		m.state = State{Phase: "idle", Backends: m.backends(), RecentLog: []string{}}
		t.Cleanup(m.Close)
		if _, err := m.handleUpgrade(mustJSON(t, upgradeParams{Mode: "system"})); err != nil {
			t.Fatalf("exit %d: handleUpgrade = %v", code, err)
		}
		waitFor(t, func() bool {
			state := m.snapshot().(State)
			return state.Phase == "idle" && state.Count == 1 && readFile(t, logPath) != ""
		})
	}
}
