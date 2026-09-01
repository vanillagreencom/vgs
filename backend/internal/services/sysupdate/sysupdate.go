package sysupdate

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"vshell/backend/internal/execbound"
	"vshell/backend/internal/server"
)

const refreshTimeout = 2 * time.Minute

type Manager struct {
	srv *server.Server
	log *slog.Logger

	checkupdates string
	paru         string
	pacman       string
	flatpak      string
	vshell       string
	terminalExec string

	mu            sync.Mutex
	state         State
	refreshCancel context.CancelFunc
	acquireCount  int
	scheduleTimer *time.Timer
	closed        bool
	// opGen invalidates in-flight operation completions: it is bumped whenever
	// an operation starts or is canceled, and a completion whose captured
	// generation no longer matches must not touch state (a cancel or a newer
	// operation owns it now).
	opGen uint64
}

type State struct {
	Phase                string      `json:"phase"`
	Distro               string      `json:"distro"`
	DistroPretty         string      `json:"distroPretty"`
	Backends             []Backend   `json:"backends"`
	Packages             []Package   `json:"packages"`
	Count                int         `json:"count"`
	IntervalSeconds      int         `json:"intervalSeconds"`
	LastCheckUnix        int64       `json:"lastCheckUnix"`
	LastSuccessUnix      int64       `json:"lastSuccessUnix"`
	NextCheckUnix        int64       `json:"nextCheckUnix"`
	OperationID          string      `json:"operationId"`
	OperationStartedUnix int64       `json:"operationStartedUnix"`
	RecentLog            []string    `json:"recentLog"`
	Error                *StateError `json:"error,omitempty"`
}

type Backend struct {
	ID             string `json:"id"`
	DisplayName    string `json:"displayName"`
	Repo           string `json:"repo"`
	NeedsAuth      bool   `json:"needsAuth"`
	RunsInTerminal bool   `json:"runsInTerminal"`
}

type Package struct {
	Name         string `json:"name"`
	Repo         string `json:"repo"`
	Backend      string `json:"backend"`
	FromVersion  string `json:"fromVersion"`
	ToVersion    string `json:"toVersion"`
	SizeBytes    int64  `json:"sizeBytes"`
	ChangelogURL string `json:"changelogUrl"`
}

type StateError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type refreshParams struct {
	Force bool `json:"force"`
}

type upgradeParams struct {
	IncludeFlatpak bool   `json:"includeFlatpak"`
	IncludeAUR     bool   `json:"includeAUR"`
	Terminal       string `json:"terminal"`
	DryRun         bool   `json:"dryRun"`
	Mode           string `json:"mode"`
}

type intervalParams struct {
	Seconds int `json:"seconds"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	m := &Manager{srv: srv, log: log}
	m.checkupdates, _ = exec.LookPath("checkupdates")
	m.paru, _ = exec.LookPath("paru")
	m.pacman, _ = exec.LookPath("pacman")
	m.flatpak, _ = exec.LookPath("flatpak")
	m.vshell = vshellCLIPath()
	m.terminalExec, _ = exec.LookPath("xdg-terminal-exec")
	if m.checkupdates == "" && m.paru == "" && m.flatpak == "" {
		return nil, fmt.Errorf("no supported update counter found")
	}
	distro, pretty := osRelease()
	m.state = State{
		Phase:           "idle",
		Distro:          distro,
		DistroPretty:    pretty,
		Backends:        m.backends(),
		Packages:        []Package{},
		IntervalSeconds: 1800,
		RecentLog:       []string{"sysupdate ready"},
	}
	srv.Register("sysupdate", "sysupdate.getState", m.handleGetState)
	srv.Register("sysupdate", "sysupdate.refresh", m.handleRefresh)
	srv.Register("sysupdate", "sysupdate.upgrade", m.handleUpgrade)
	srv.Register("sysupdate", "sysupdate.cancel", m.handleCancel)
	srv.Register("sysupdate", "sysupdate.setInterval", m.handleSetInterval)
	srv.Register("sysupdate", "sysupdate.acquire", m.handleAcquire)
	srv.Register("sysupdate", "sysupdate.release", m.handleRelease)
	srv.RegisterSnapshot("sysupdate", m.snapshot)
	return m, nil
}

func (m *Manager) Close() {
	m.mu.Lock()
	m.closed = true
	m.stopScheduleLocked()
	if m.refreshCancel != nil {
		m.refreshCancel()
	}
	m.mu.Unlock()
}

func (m *Manager) handleGetState(json.RawMessage) (any, error) {
	return m.snapshot(), nil
}

func (m *Manager) handleRefresh(params json.RawMessage) (any, error) {
	var p refreshParams
	if len(params) > 0 {
		_ = json.Unmarshal(params, &p)
	}
	return m.refresh(p.Force)
}

func (m *Manager) refresh(force bool) (any, error) {
	m.mu.Lock()
	if m.state.Phase != "idle" {
		state := m.state
		m.mu.Unlock()
		return state, nil
	}
	// A non-forced refresh right after a completed one (widget opening, timer
	// coinciding with a manual check) reuses the fresh result; force always
	// re-runs the collectors.
	if !force && m.state.LastCheckUnix > 0 && time.Now().Unix()-m.state.LastCheckUnix < 30 {
		state := m.state
		m.mu.Unlock()
		return state, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), refreshTimeout)
	m.refreshCancel = cancel
	m.opGen++
	gen := m.opGen
	started := time.Now().Unix()
	m.state.Phase = "refreshing"
	m.state.OperationID = fmt.Sprintf("refresh-%d", started)
	m.state.OperationStartedUnix = started
	m.state.Error = nil
	m.addLogLocked("checking for updates")
	state := m.state
	m.mu.Unlock()
	m.srv.Broadcast("sysupdate", state)

	packages, logs, err := m.collectUpdates(ctx)

	m.mu.Lock()
	cancel()
	if gen != m.opGen {
		// Canceled or superseded while collecting: a cancel or a newer
		// operation owns the state now; discard this result.
		state := m.state
		m.mu.Unlock()
		return state, nil
	}
	m.refreshCancel = nil
	m.state.Phase = "idle"
	m.state.OperationID = ""
	m.state.OperationStartedUnix = 0
	m.state.LastCheckUnix = time.Now().Unix()
	if err != nil {
		m.state.Error = &StateError{Code: "refresh_failed", Message: err.Error()}
		m.addLogLocked(err.Error())
	} else {
		m.state.Error = nil
		m.state.Packages = packages
		m.state.Count = len(packages)
		m.state.LastSuccessUnix = m.state.LastCheckUnix
		m.addLogLocked(fmt.Sprintf("%d updates available", len(packages)))
	}
	for _, line := range logs {
		m.addLogLocked(line)
	}
	m.scheduleNextLocked(time.Now())
	state = m.state
	m.mu.Unlock()
	m.srv.Broadcast("sysupdate", state)
	return state, nil
}

func (m *Manager) handleUpgrade(params json.RawMessage) (any, error) {
	var p upgradeParams
	if len(params) > 0 {
		_ = json.Unmarshal(params, &p)
	}
	if p.DryRun {
		return m.snapshot(), nil
	}
	cmdline := m.upgradeCommand(p)
	if cmdline == "" {
		return m.failIdle("upgrade_unavailable", "no supported upgrade command found")
	}
	terminal := strings.TrimSpace(p.Terminal)
	if terminal == "" {
		terminal = os.Getenv("TERMINAL")
	}
	argv, err := m.terminalArgv(terminal, cmdline)
	if err != nil {
		return m.failIdle("upgrade_unavailable", err.Error())
	}
	m.mu.Lock()
	if m.state.Phase == "upgrading" {
		state := m.state
		m.mu.Unlock()
		return state, fmt.Errorf("an upgrade is already running")
	}
	if m.state.Phase == "refreshing" && m.refreshCancel != nil {
		// The upgrade takes over: cancel the in-flight refresh so its
		// completion cannot clobber the upgrading state.
		m.refreshCancel()
		m.refreshCancel = nil
		m.addLogLocked("refresh canceled for upgrade")
	}
	m.opGen++
	gen := m.opGen
	m.state.Phase = "upgrading"
	m.state.OperationID = fmt.Sprintf("upgrade-%d", time.Now().Unix())
	m.state.OperationStartedUnix = time.Now().Unix()
	m.state.Error = nil
	m.addLogLocked("launching terminal updater")
	state := m.state
	m.mu.Unlock()
	m.srv.Broadcast("sysupdate", state)

	cmd := exec.Command(argv[0], argv[1:]...)
	if err := cmd.Start(); err != nil {
		return m.failUpgrade(gen, err.Error())
	}
	go m.waitUpgrade(cmd, gen)
	m.mu.Lock()
	m.addLogLocked("terminal updater launched")
	state = m.state
	m.mu.Unlock()
	m.srv.Broadcast("sysupdate", state)
	return state, nil
}

func (m *Manager) handleCancel(json.RawMessage) (any, error) {
	m.mu.Lock()
	m.opGen++ // invalidate any in-flight completion so it cannot clobber state
	if m.refreshCancel != nil {
		m.refreshCancel()
		m.refreshCancel = nil
		m.addLogLocked("refresh canceled")
	}
	m.state.Phase = "idle"
	m.state.OperationID = ""
	m.state.OperationStartedUnix = 0
	m.scheduleNextLocked(time.Now())
	state := m.state
	m.mu.Unlock()
	m.srv.Broadcast("sysupdate", state)
	return state, nil
}

func (m *Manager) handleSetInterval(params json.RawMessage) (any, error) {
	var p intervalParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.Seconds < 0 {
		return nil, fmt.Errorf("seconds must be non-negative")
	}
	m.mu.Lock()
	m.state.IntervalSeconds = p.Seconds
	m.scheduleNextLocked(time.Now())
	state := m.state
	m.mu.Unlock()
	m.srv.Broadcast("sysupdate", state)
	return state, nil
}

func (m *Manager) handleAcquire(json.RawMessage) (any, error) {
	m.mu.Lock()
	m.acquireCount++
	m.scheduleNextLocked(time.Now())
	state := m.state
	m.mu.Unlock()
	m.srv.Broadcast("sysupdate", state)
	return state, nil
}

func (m *Manager) handleRelease(json.RawMessage) (any, error) {
	m.mu.Lock()
	if m.acquireCount > 0 {
		m.acquireCount--
	}
	m.scheduleNextLocked(time.Now())
	state := m.state
	m.mu.Unlock()
	m.srv.Broadcast("sysupdate", state)
	return state, nil
}

func (m *Manager) snapshot() any {
	m.mu.Lock()
	defer m.mu.Unlock()
	state := m.state
	if state.Packages == nil {
		state.Packages = []Package{}
	}
	if state.Backends == nil {
		state.Backends = []Backend{}
	}
	if state.RecentLog == nil {
		state.RecentLog = []string{}
	}
	return state
}

func (m *Manager) backends() []Backend {
	var backends []Backend
	if m.checkupdates != "" {
		backends = append(backends, Backend{ID: "pacman", DisplayName: "Pacman", Repo: "system", NeedsAuth: true, RunsInTerminal: true})
	}
	if m.paru != "" {
		backends = append(backends, Backend{ID: "paru", DisplayName: "paru AUR", Repo: "aur", NeedsAuth: false, RunsInTerminal: true})
	}
	if m.flatpak != "" {
		backends = append(backends, Backend{ID: "flatpak", DisplayName: "Flatpak", Repo: "flatpak", NeedsAuth: false, RunsInTerminal: true})
	}
	return backends
}

func (m *Manager) collectUpdates(ctx context.Context) ([]Package, []string, error) {
	var packages []Package
	var logs []string
	if m.checkupdates != "" {
		out, err := commandOutput(ctx, true, m.checkupdates)
		if err != nil && len(bytes.TrimSpace(out)) == 0 {
			return nil, logs, err
		}
		repoPackages := parseCheckupdates(out)
		packages = append(packages, repoPackages...)
		logs = append(logs, fmt.Sprintf("pacman: %d updates", len(repoPackages)))
	}
	if m.paru != "" {
		out, err := commandOutput(ctx, false, m.paru, "-Qua")
		if err != nil && len(bytes.TrimSpace(out)) > 0 {
			logs = append(logs, "paru returned partial output")
		} else if err != nil {
			logs = append(logs, "paru AUR check unavailable: "+err.Error())
		}
		aurPackages := parseParu(out)
		packages = append(packages, aurPackages...)
		logs = append(logs, fmt.Sprintf("aur: %d updates", len(aurPackages)))
	}
	if m.flatpak != "" {
		out, err := commandOutput(ctx, false, m.flatpak, "remote-ls", "--updates", "--columns=application,branch")
		if err != nil && len(bytes.TrimSpace(out)) == 0 {
			logs = append(logs, "flatpak check unavailable: "+err.Error())
		}
		flatpakPackages := parseFlatpak(out)
		packages = append(packages, flatpakPackages...)
		if len(flatpakPackages) > 0 {
			logs = append(logs, fmt.Sprintf("flatpak: %d updates", len(flatpakPackages)))
		}
	}
	return packages, logs, nil
}

func (m *Manager) upgradeCommand(p upgradeParams) string {
	var parts []string
	switch p.Mode {
	case "aur":
		if m.paru != "" {
			parts = append(parts, shellQuote(m.paru)+" -Sua")
		}
	case "system":
		if m.pacman != "" {
			parts = append(parts, "sudo "+shellQuote(m.pacman)+" -Syu")
		}
	default:
		if m.pacman != "" {
			parts = append(parts, "sudo "+shellQuote(m.pacman)+" -Syu")
		}
		if p.IncludeAUR && m.paru != "" {
			parts = append(parts, shellQuote(m.paru)+" -Sua")
		}
	}
	if len(parts) == 0 && p.IncludeAUR && m.paru != "" {
		parts = append(parts, shellQuote(m.paru)+" -Sua")
	} else if len(parts) == 0 && m.pacman != "" {
		parts = append(parts, "sudo "+shellQuote(m.pacman)+" -Syu")
	}
	if p.IncludeFlatpak && m.flatpak != "" {
		parts = append(parts, shellQuote(m.flatpak)+" update")
	}
	if len(parts) == 0 {
		return ""
	}
	return strings.Join(parts, " && ") + "; printf '\\nUpdates command finished. Press Enter to close... '; read -r _"
}

// vshellCLIPath locates the VGS CLI the same way the QML side anchors on
// Paths.vshellCli, rather than trusting the daemon's inherited PATH. A source
// install puts the CLI only in ~/.local/bin, which a systemd user unit need not
// have on PATH; falling through to the xdg-terminal-exec branch there would
// walk straight back into the VGS-54 failure. `bin/vshell` exports VSHELL_ROOT
// before exec'ing the backend, so that is the reliable anchor.
func vshellCLIPath() string {
	if root := os.Getenv("VSHELL_ROOT"); root != "" {
		path := filepath.Join(root, "bin", "vshell")
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			return path
		}
	}
	if path, err := exec.LookPath("vshell"); err == nil {
		return path
	}
	if home, err := os.UserHomeDir(); err == nil {
		path := filepath.Join(home, ".local", "bin", "vshell")
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			return path
		}
	}
	return ""
}

// terminalArgv defers to `vshell terminal exec`, the single terminal resolver
// (VGS-32): it owns the VGS setting, $TERMINAL, xdg-terminals.list, the
// installed-terminal fallback and the optional uwsm scope. The backend only
// falls back to naming a terminal itself when the CLI is not on PATH, and never
// to `xdg-terminal-exec`, which no supported install route provides (VGS-54).
//
// A terminal the caller asked for is forwarded as --prefer rather than
// discarded: deferring resolution must not mean ignoring an explicit choice.
// --wait keeps this process alive for the whole upgrade, because waitUpgrade
// treats its exit as the transaction finishing; without it the helper returns
// as soon as the window is up and a second package-manager run could start on
// top of the first.
func (m *Manager) terminalArgv(terminal, cmdline string) ([]string, error) {
	if m.vshell != "" {
		argv := []string{m.vshell, "terminal", "exec", "--tui", "--wait"}
		if terminal != "" {
			argv = append(argv, "--prefer", terminal)
		}
		return append(argv, "--", "sh", "-lc", cmdline, "vshell-update"), nil
	}
	if terminal != "" {
		return []string{terminal, "-e", "sh", "-lc", cmdline, "vshell-update"}, nil
	}
	if m.terminalExec != "" {
		return []string{m.terminalExec, "--", "sh", "-lc", cmdline, "vshell-update"}, nil
	}
	return nil, fmt.Errorf("no terminal launcher found")
}

func (m *Manager) addLogLocked(line string) {
	line = strings.TrimSpace(line)
	if line == "" {
		return
	}
	m.state.RecentLog = append(m.state.RecentLog, line)
	if len(m.state.RecentLog) > 40 {
		m.state.RecentLog = m.state.RecentLog[len(m.state.RecentLog)-40:]
	}
}

func (m *Manager) failIdle(code, message string) (any, error) {
	m.mu.Lock()
	m.state.Phase = "idle"
	m.state.OperationID = ""
	m.state.OperationStartedUnix = 0
	m.state.Error = &StateError{Code: code, Message: message}
	m.addLogLocked(message)
	m.scheduleNextLocked(time.Now())
	state := m.state
	m.mu.Unlock()
	m.srv.Broadcast("sysupdate", state)
	return nil, fmt.Errorf("%s", message)
}

// failUpgrade resets an upgrade that failed to launch, unless a cancel or a
// newer operation already took over the state.
func (m *Manager) failUpgrade(gen uint64, message string) (any, error) {
	m.mu.Lock()
	if gen == m.opGen {
		m.state.Phase = "idle"
		m.state.OperationID = ""
		m.state.OperationStartedUnix = 0
		m.state.Error = &StateError{Code: "upgrade_failed", Message: message}
		m.addLogLocked(message)
		m.scheduleNextLocked(time.Now())
	}
	state := m.state
	m.mu.Unlock()
	m.srv.Broadcast("sysupdate", state)
	return nil, fmt.Errorf("%s", message)
}

func (m *Manager) waitUpgrade(cmd *exec.Cmd, gen uint64) {
	err := cmd.Wait()
	m.mu.Lock()
	if m.closed || gen != m.opGen {
		m.mu.Unlock()
		return
	}
	m.state.Phase = "idle"
	m.state.OperationID = ""
	m.state.OperationStartedUnix = 0
	if err != nil {
		m.state.Error = &StateError{Code: "upgrade_failed", Message: err.Error()}
		m.addLogLocked("terminal updater failed: " + err.Error())
	} else {
		m.state.Error = nil
		m.addLogLocked("terminal updater exited")
	}
	m.scheduleNextLocked(time.Now())
	state := m.state
	m.mu.Unlock()
	m.srv.Broadcast("sysupdate", state)
}

func (m *Manager) scheduledRefresh() {
	m.mu.Lock()
	if m.closed || m.acquireCount <= 0 || m.state.IntervalSeconds <= 0 {
		m.scheduleNextLocked(time.Now())
		m.mu.Unlock()
		return
	}
	if m.state.Phase == "refreshing" || m.state.Phase == "upgrading" {
		m.scheduleNextLocked(time.Now())
		state := m.state
		m.mu.Unlock()
		m.srv.Broadcast("sysupdate", state)
		return
	}
	m.mu.Unlock()
	_, _ = m.refresh(false)
}

func (m *Manager) scheduleNextLocked(now time.Time) {
	m.stopScheduleLocked()
	if m.closed || m.acquireCount <= 0 || m.state.IntervalSeconds <= 0 {
		m.state.NextCheckUnix = 0
		return
	}
	nextUnix := now.Unix() + int64(m.state.IntervalSeconds)
	if m.state.LastCheckUnix > 0 {
		candidate := m.state.LastCheckUnix + int64(m.state.IntervalSeconds)
		if candidate > now.Unix() {
			nextUnix = candidate
		}
	}
	m.state.NextCheckUnix = nextUnix
	delay := time.Until(time.Unix(nextUnix, 0))
	if delay < 0 {
		delay = 0
	}
	m.scheduleTimer = time.AfterFunc(delay, m.scheduledRefresh)
}

func (m *Manager) stopScheduleLocked() {
	if m.scheduleTimer != nil {
		m.scheduleTimer.Stop()
		m.scheduleTimer = nil
	}
}

func commandOutput(ctx context.Context, allowNoUpdatesExit bool, name string, args ...string) ([]byte, error) {
	res, err := execbound.Command(ctx, name, args...).Output()
	out := res.Out
	if err != nil {
		if execbound.Interrupted(err) {
			return out, err
		}
		if ee, ok := err.(*exec.ExitError); ok {
			if len(ee.Stderr) > 0 {
				return out, fmt.Errorf("%s", strings.TrimSpace(string(ee.Stderr)))
			}
			if allowNoUpdatesExit && ee.ExitCode() == 2 && len(bytes.TrimSpace(out)) == 0 {
				return out, nil
			}
		}
	}
	return out, err
}

func parseCheckupdates(out []byte) []Package {
	var packages []Package
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 4 && fields[2] == "->" {
			packages = append(packages, Package{Name: fields[0], Repo: "system", Backend: "pacman", FromVersion: fields[1], ToVersion: fields[3]})
			continue
		}
		if len(fields) >= 2 {
			packages = append(packages, Package{Name: fields[0], Repo: "system", Backend: "pacman", ToVersion: fields[len(fields)-1]})
		}
	}
	return packages
}

func parseParu(out []byte) []Package {
	var packages []Package
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 4 && fields[2] == "->" {
			packages = append(packages, Package{Name: fields[0], Repo: "aur", Backend: "paru", FromVersion: fields[1], ToVersion: fields[3]})
			continue
		}
		if len(fields) >= 2 {
			packages = append(packages, Package{Name: fields[0], Repo: "aur", Backend: "paru", ToVersion: fields[len(fields)-1]})
		}
	}
	return packages
}

func parseFlatpak(out []byte) []Package {
	var packages []Package
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "Application") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 1 {
			pkg := Package{Name: fields[0], Repo: "flatpak", Backend: "flatpak"}
			if len(fields) > 1 {
				pkg.ToVersion = fields[1]
			}
			packages = append(packages, pkg)
		}
	}
	return packages
}

func osRelease() (string, string) {
	raw, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return "", ""
	}
	values := map[string]string{}
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	for scanner.Scan() {
		line := scanner.Text()
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		unquoted, err := strconv.Unquote(value)
		if err == nil {
			value = unquoted
		}
		values[key] = value
	}
	return values["ID"], firstNonEmpty(values["PRETTY_NAME"], values["NAME"])
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
