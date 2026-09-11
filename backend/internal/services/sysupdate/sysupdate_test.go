package sysupdate

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"vshell/backend/internal/execbound"
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
// nothing else, so there is exactly one spelling of "how to upgrade". The
// terminal must stay open for the upgrade's whole lifetime (waitUpgrade treats
// the launched process exiting as the upgrade finishing), and an explicit
// terminal from the caller must reach the resolver.
func TestTerminalArgv(t *testing.T) {
	cases := []struct {
		name     string
		terminal string
		mode     string
		check    func(t *testing.T, argv []string)
	}{
		{"runs the CLI updater", "", "tools", func(t *testing.T, argv []string) {
			if len(argv) < 5 || argv[len(argv)-5] != "--" || argv[len(argv)-4] != "/usr/bin/vshell" || argv[len(argv)-3] != "update" || argv[len(argv)-2] != "run" || argv[len(argv)-1] != "tools" {
				t.Fatalf("terminal argv tail = %#v, want -- vshell update run tools", argv)
			}
		}},
		{"waits for the upgrade to finish", "", "all", func(t *testing.T, argv []string) {
			if !contains(strings.Join(argv, " "), "--wait") {
				t.Fatalf("terminal argv = %#v, want --wait", argv)
			}
		}},
		{"forwards the caller's terminal", "foot", "all", func(t *testing.T, argv []string) {
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
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := &Manager{vshell: "/usr/bin/vshell"}
			argv, err := m.terminalArgv(tc.terminal, tc.mode)
			if err != nil {
				t.Fatal(err)
			}
			tc.check(t, argv)
		})
	}
	if _, err := (&Manager{}).terminalArgv("", "all"); err == nil {
		t.Fatal("terminalArgv without the vshell CLI must fail")
	}
}

func TestParseMiseOutdated(t *testing.T) {
	// Three ids whose backend-and-owner order is not their tool-name order.
	packages, err := parseMiseOutdated([]byte(`{"npm:@deepseek-ai/dsh": {"name": "npm:@deepseek-ai/dsh", "requested": "latest", "current": "0.1.0", "latest": "0.1.1"}, "github:vercel-labs/fx": {"name": "github:vercel-labs/fx", "requested": "latest", "current": "0.0.7", "latest": "0.0.8"}, "herdr": {"name": "herdr", "requested": "latest", "current": "0.9.0", "latest": "0.9.1"}}`))
	if err != nil {
		t.Fatal(err)
	}
	if len(packages) != 3 {
		t.Fatalf("len(packages) = %d, want 3", len(packages))
	}
	if packages[0].Name != "dsh" || packages[0].Repo != "tools" || packages[0].Backend != "mise" || packages[0].FromVersion != "0.1.0" || packages[0].ToVersion != "0.1.1" {
		t.Fatalf("unexpected package: %#v", packages[0])
	}
	if names := []string{packages[0].Name, packages[1].Name, packages[2].Name}; names[1] != "fx" || names[2] != "herdr" {
		t.Fatalf("packages must be sorted by tool name, got %v", names)
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

// The update list names a tool the way every other surface does. mise files a
// package under its backend and owner for every backend but the default
// registry, so the raw ids carry a prefix on some rows and not others.
func TestMiseToolName(t *testing.T) {
	cases := []struct{ id, want string }{
		{"claude", "claude"},
		{"node", "node"},
		{"npm:@deepseek-ai/dsh", "dsh"},
		{"npm:@xai-official/grok", "grok"},
		{"aqua:google-antigravity/antigravity-cli", "antigravity-cli"},
		{"github:can1357/oh-my-pi", "oh-my-pi"},
		{"github:vercel-labs/fx", "fx"},
		{"pipx:hermes-agent", "hermes-agent"},
		{"http:muse", "muse"},
		{"npm:vercel", "vercel"},
		// Nothing follows the owner, so the id is all there is to show.
		{"github:owner/", "github:owner/"},
		{"npm:", "npm:"},
	}
	for _, tc := range cases {
		if got := miseToolName(tc.id); got != tc.want {
			t.Errorf("miseToolName(%q) = %q, want %q", tc.id, got, tc.want)
		}
	}
}

func TestBackendsListsMise(t *testing.T) {
	m := &Manager{mise: "/usr/bin/mise"}
	backends := m.backends()
	if len(backends) != 1 || backends[0].ID != "mise" || backends[0].Repo != "tools" || backends[0].NeedsAuth {
		t.Fatalf("backends = %#v, want one mise/tools backend without auth", backends)
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

// Close waits out every refresh still unwinding, not only the newest. Cancelling
// a refresh only closes its context: os/exec calls Cmd.Cancel from its own
// watcher goroutine, so a Close that returned at refreshCancel() would let the
// daemon exit before the collector's commands were signalled at all. And
// handleCancel returns the manager to idle before the cancelled collector has
// returned, so a second refresh can start and finish while the first is still
// unwinding; tracking one refresh let Close wait on the finished second and
// return with the first one's commands alive.
func TestCloseWaitsForEveryRefreshStillUnwinding(t *testing.T) {
	cmd, pidPath := slowThenFastUpdateCommand(t)
	m := &Manager{srv: server.New(0, nil), checkupdates: cmd}
	m.state = State{Phase: "idle", Backends: m.backends(), RecentLog: []string{}}

	go func() { _, _ = m.refresh(true) }()
	waitFor(t, func() bool { return readFile(t, pidPath) != "" })

	// Taken before the cancel, so the WaitDelay the collector unwinds over starts
	// at or after it and the assertion below needs no tolerance.
	cancelled := time.Now()
	if _, err := m.handleCancel(nil); err != nil {
		t.Fatal(err)
	}

	// The second call to the fake exits at once, so this refresh completes while
	// the first is still unwinding and becomes the newest one Close could see.
	if _, err := m.refresh(true); err != nil {
		t.Fatal(err)
	}
	if state := m.snapshot().(State); state.LastCheckUnix == 0 {
		t.Fatal("the second refresh did not complete, so it is not the newer one Close must look past")
	}

	start := time.Now()
	m.Close()
	elapsed := time.Since(start)

	if unwound := time.Since(cancelled); unwound < execbound.DefaultWaitDelay {
		t.Fatalf("Close returned %v after the cancel, inside the first refresh's %v unwind",
			unwound, execbound.DefaultWaitDelay)
	}
	if elapsed > closeGrace {
		t.Fatalf("Close took %v, want no more than the %v grace", elapsed, closeGrace)
	}
}

// slowThenFastUpdateCommand is a checkupdates whose first call leaves a
// descendant holding its stdout and then waits, so cancelling that call unwinds
// over execbound's WaitDelay instead of instantly. Every later call exits at
// once, so a refresh started after the first can finish while the first still
// unwinds. checkupdates does not ask for the process-group bound, so nothing
// signals the holder: cleanup kills it by the pid it recorded.
func slowThenFastUpdateCommand(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	pidPath := filepath.Join(dir, "holder.pid")
	firstPath := filepath.Join(dir, "first-call")
	path := filepath.Join(dir, "checkupdates")
	body := "#!/bin/sh\n" +
		"if [ -f '" + firstPath + "' ]; then exit 0; fi\n" +
		": > '" + firstPath + "'\n" +
		"sleep 30 &\n" +
		"echo $! > '" + pidPath + "'\n" +
		"exec sleep 30\n"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if pid, err := strconv.Atoi(strings.TrimSpace(readFile(t, pidPath))); err == nil {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	return path, pidPath
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
