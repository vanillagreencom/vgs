package cloudsync

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"vshell/backend/internal/server"
)

// broadcastInterval throttles progress pushes to the shell. Fast enough for a
// live speed readout, slow enough that a busy sync does not flood the socket.
const broadcastInterval = 500 * time.Millisecond

const trashPruneInterval = 6 * time.Hour

// accountCheckInterval refreshes account health and quota because tokens and
// storage use can change without user action.
const accountCheckInterval = 30 * time.Minute

// Manager owns cloud sync configuration, runtime state, and the rclone control
// daemon. QML consumes its snapshots.
type Manager struct {
	srv    *server.Server
	log    *slog.Logger
	binary string
	client *rcClient
	daemon *rcd
	store  *store

	canMount bool
	watcher  *watcher

	// shutdown is cancelled by Close, and tasks tracks the background account
	// probes so shutdown can wait for them instead of leaving goroutines
	// writing state and broadcasting against a server that is going away.
	shutdown  context.Context
	stopTasks context.CancelFunc
	tasks     sync.WaitGroup

	mu           sync.Mutex
	statuses     map[string]*FolderStatus
	jobs         map[string]*activeJob
	timers       map[string]*time.Timer
	failures     map[string]int
	startupTimer *time.Timer
	pruneTimer   *time.Timer
	accountTimer *time.Timer
	accounts     []Account
	// daemonGeneration distinguishes job IDs reused by a restarted rclone daemon.
	daemonGeneration uint64
	providers        map[string]providerDetails
	providersLoaded  bool
	// providersOnce serializes the provider-table fetch. Separate from mu
	// because the fetch is a blocking rc call that must not hold the state lock.
	providersOnce   sync.Mutex
	conflicts       []Conflict
	recent          []RecentFile
	global          GlobalStats
	oauth           OAuthState
	oauthSession    *oauthSession
	progressRunning bool
	closed          bool
	lastBroadcast   time.Time
	broadcastTimer  *time.Timer
}

// Register wires the service. Without rclone the capability is simply not
// advertised and the shell hides the feature behind an install hint.
func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	binary, err := exec.LookPath("rclone")
	if err != nil {
		return nil, fmt.Errorf("rclone not found")
	}
	st, err := newStore()
	if err != nil {
		return nil, err
	}

	m := &Manager{
		srv:      srv,
		log:      log,
		binary:   binary,
		client:   newRCClient(),
		store:    st,
		canMount: fuseAvailable(),
		statuses: map[string]*FolderStatus{},
		jobs:     map[string]*activeJob{},
		timers:   map[string]*time.Timer{},
		failures: map[string]int{},
	}
	m.shutdown, m.stopTasks = context.WithCancel(context.Background())
	if len(st.rejected) > 0 {
		log.Warn("cloudsync ignored unsafe persisted folders",
			"count", len(st.rejected), "folders", st.rejected)
	}
	for _, warning := range st.snapshotWarnings() {
		log.Warn("cloudsync loaded with warning", "warning", warning)
	}
	m.daemon = newRCD(binary, m.client, m.onDaemonUp, m.onDaemonDown)

	if w, werr := newWatcher(log, m.onWatchDirty); werr != nil {
		// Scheduled sync remains available when filesystem watching is unavailable.
		log.Warn("cloudsync real-time watcher unavailable", "err", werr)
	} else {
		m.watcher = w
		w.onDegraded = m.onWatchDegraded
	}

	srv.Register("cloudsync", "cloudsync.getState", m.handleGetState)
	srv.Register("cloudsync", "cloudsync.listProviders", m.handleListProviders)
	srv.Register("cloudsync", "cloudsync.listRemotes", m.handleListRemotes)
	srv.Register("cloudsync", "cloudsync.addRemote", m.handleAddRemote)
	srv.Register("cloudsync", "cloudsync.updateRemote", m.handleUpdateRemote)
	srv.Register("cloudsync", "cloudsync.removeRemote", m.handleRemoveRemote)
	srv.Register("cloudsync", "cloudsync.reconnectRemote", m.handleReconnectRemote)
	srv.Register("cloudsync", "cloudsync.checkRemote", m.handleCheckRemote)
	srv.Register("cloudsync", "cloudsync.testRemote", m.handleTestRemote)
	srv.Register("cloudsync", "cloudsync.about", m.handleAbout)
	srv.Register("cloudsync", "cloudsync.startOAuth", m.handleStartOAuth)
	srv.Register("cloudsync", "cloudsync.cancelOAuth", m.handleCancelOAuth)
	srv.Register("cloudsync", "cloudsync.browse", m.handleBrowse)
	srv.Register("cloudsync", "cloudsync.addFolder", m.handleAddFolder)
	srv.Register("cloudsync", "cloudsync.updateFolder", m.handleUpdateFolder)
	srv.Register("cloudsync", "cloudsync.removeFolder", m.handleRemoveFolder)
	srv.Register("cloudsync", "cloudsync.syncNow", m.handleSyncNow)
	srv.Register("cloudsync", "cloudsync.resync", m.handleResync)
	srv.Register("cloudsync", "cloudsync.cancelJob", m.handleCancelJob)
	srv.Register("cloudsync", "cloudsync.pauseFolder", m.handlePauseFolder)
	srv.Register("cloudsync", "cloudsync.resumeFolder", m.handleResumeFolder)
	srv.Register("cloudsync", "cloudsync.pauseAll", m.handlePauseAll)
	srv.Register("cloudsync", "cloudsync.resumeAll", m.handleResumeAll)
	srv.Register("cloudsync", "cloudsync.updateSettings", m.handleUpdateSettings)
	srv.Register("cloudsync", "cloudsync.setBandwidthLimit", m.handleSetBandwidthLimit)
	srv.Register("cloudsync", "cloudsync.getHistory", m.handleGetHistory)
	srv.Register("cloudsync", "cloudsync.getConflicts", m.handleGetConflicts)
	srv.Register("cloudsync", "cloudsync.resolveConflict", m.handleResolveConflict)
	srv.Register("cloudsync", "cloudsync.mount", m.handleMount)
	srv.Register("cloudsync", "cloudsync.unmount", m.handleUnmount)
	srv.Register("cloudsync", "cloudsync.emptyTrash", m.handleEmptyTrash)
	srv.Register("cloudsync", "cloudsync.restartDaemon", m.handleRestartDaemon)
	srv.RegisterSnapshot("cloudsync", func() any { return m.snapshot() })

	// Starting the daemon can take a moment and must not delay shell startup.
	go func() {
		if err := m.daemon.start(); err != nil {
			m.log.Warn("cloudsync could not start rclone control daemon", "err", err)
			m.broadcastNow()
		}
	}()
	m.schedulePrune()
	m.scheduleAccountCheck()
	return m, nil
}

func (m *Manager) onDaemonUp(version string) {
	// Daemon job IDs can repeat after a restart. Provider metadata must also be
	// fetched again.
	m.mu.Lock()
	m.daemonGeneration++
	m.providers = nil
	m.providersLoaded = false
	m.mu.Unlock()

	_ = m.applyBandwidth(m.store.snapshotSettings())
	m.refreshAccounts()
	if err := m.rescanAllConflicts(); err != nil {
		m.log.Warn("cloudsync conflict rescan degraded", "err", err)
	}
	m.refreshMountStates()
	m.mountConfiguredFolders()
	m.syncWatchers()
	m.rescheduleAll()
	m.scheduleStartupSweep()
	m.log.Info("cloudsync ready", "rclone", version)
	m.broadcastNow()
}

// onDaemonDown marks running jobs as interrupted because they do not survive an
// rclone restart.
func (m *Manager) onDaemonDown(reason string) {
	m.mu.Lock()
	for id := range m.jobs {
		st := m.statusLocked(id)
		st.State = StateError
		st.LastError = "sync was interrupted"
		st.Transferring = nil
		st.Speed = 0
	}
	m.jobs = map[string]*activeJob{}
	m.global = GlobalStats{}
	m.daemonGeneration++
	m.mu.Unlock()
	m.log.Warn("cloudsync rclone daemon down", "reason", reason)
	m.broadcastNow()
}

// onWatchDegraded publishes watcher failures between configuration updates so
// folder state does not continue to report active watching.
func (m *Manager) onWatchDegraded() {
	m.syncWatchers()
	m.broadcastNow()
}

// Close cancels timers and background work, releases watches, and requests mount
// and daemon shutdown.
func (m *Manager) Close() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	m.closed = true
	for _, timer := range m.timers {
		if timer != nil {
			timer.Stop()
		}
	}
	m.timers = map[string]*time.Timer{}
	if m.startupTimer != nil {
		m.startupTimer.Stop()
	}
	if m.pruneTimer != nil {
		m.pruneTimer.Stop()
	}
	if m.accountTimer != nil {
		m.accountTimer.Stop()
	}
	if m.broadcastTimer != nil {
		m.broadcastTimer.Stop()
	}
	session := m.oauthSession
	m.oauthSession = nil
	m.mu.Unlock()

	// Cancels in-flight account probes, then waits for them: they write
	// m.accounts and broadcast, so letting them outlive Close means state
	// changes after shutdown.
	m.stopTasks()
	m.tasks.Wait()

	// Kill the sign-in process group so descendants do not retain the callback port
	// after shutdown.
	session.kill()
	if m.watcher != nil {
		m.watcher.close()
	}
	m.unmountAll()
	m.daemon.close()
}

func (m *Manager) snapshot() State {
	folders := m.store.snapshotFolders()
	settings := m.store.snapshotSettings()
	if settings.MountRoot == "" {
		settings.MountRoot = m.store.mountRoot
	}
	version, daemonErr := m.daemon.info()

	m.mu.Lock()
	defer m.mu.Unlock()

	statuses := make([]FolderStatus, 0, len(folders))
	transferring := make([]Transfer, 0, 8)
	for _, folder := range folders {
		st := m.statusLocked(folder.ID)
		copied := *st
		copied.Transferring = append([]Transfer{}, st.Transferring...)
		// Paused folders are shown as paused even if their last run errored:
		// the actionable state is "you turned this off".
		if folder.Paused && copied.State != StateSyncing {
			copied.State = StatePaused
		} else if folder.Mode.NeedsResync() && !folder.ResyncDone && copied.State != StateSyncing {
			copied.State = StateNeedsResync
		}
		statuses = append(statuses, copied)
		transferring = append(transferring, copied.Transferring...)
	}

	conflicts := append([]Conflict{}, m.conflicts...)
	sort.Slice(conflicts, func(i, j int) bool { return conflicts[i].RelPath < conflicts[j].RelPath })

	return State{
		Available:     true,
		DaemonRunning: m.daemon.running(),
		DaemonError:   daemonErr,
		RcloneVersion: version,
		CanMount:      m.canMount,
		Paused:        settings.Paused,
		Accounts:      append([]Account{}, m.accounts...),
		Folders:       folders,
		Statuses:      statuses,
		Transferring:  transferring,
		Recent:        append([]RecentFile{}, m.recent...),
		Conflicts:     conflicts,
		History:       m.store.snapshotHistory(),
		Warnings:      m.store.snapshotWarnings(),
		Global:        m.global,
		Settings:      settings,
		OAuth:         m.oauth,
	}
}

func (m *Manager) broadcastNow() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	if m.broadcastTimer != nil {
		m.broadcastTimer.Stop()
		m.broadcastTimer = nil
	}
	m.lastBroadcast = time.Now()
	m.mu.Unlock()
	m.srv.Broadcast("cloudsync", m.snapshot())
}

func (m *Manager) broadcastThrottled() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	since := time.Since(m.lastBroadcast)
	if since >= broadcastInterval {
		m.lastBroadcast = time.Now()
		m.mu.Unlock()
		m.srv.Broadcast("cloudsync", m.snapshot())
		return
	}
	if m.broadcastTimer != nil {
		m.mu.Unlock()
		return
	}
	m.broadcastTimer = time.AfterFunc(broadcastInterval-since, func() {
		m.mu.Lock()
		m.broadcastTimer = nil
		m.mu.Unlock()
		m.broadcastNow()
	})
	m.mu.Unlock()
}

// applyBandwidth returns control-call errors so a saved limit that did not take
// effect reaches the user.
func (m *Manager) applyBandwidth(settings Settings) error {
	rate := bandwidthRate(settings.BandwidthUp, settings.BandwidthDown)
	if err := m.client.callTimeout("core/bwlimit", map[string]any{"rate": rate}, nil, 10*time.Second); err != nil {
		m.log.Warn("cloudsync could not apply bandwidth limit", "rate", rate, "err", err)
		return err
	}
	return nil
}

// bandwidthRate renders rclone's UP:DOWN limit string. "off" disables a side.
func bandwidthRate(up, down string) string {
	up = strings.TrimSpace(up)
	down = strings.TrimSpace(down)
	if up == "" && down == "" {
		return "off"
	}
	if up == "" {
		up = "off"
	}
	if down == "" {
		down = "off"
	}
	return up + ":" + down
}

// maxConcurrency limits rclone workers to bound connection and file-descriptor
// use.
const maxConcurrency = 64

// validateSettings clamps and checks the fields a client can set. mergeSettings
// only floors zero values, so without this an update could set an unbounded
// concurrency or point the mount root anywhere the user can write.
func validateSettings(s *Settings) error {
	if s.Transfers > maxConcurrency {
		s.Transfers = maxConcurrency
	}
	if s.Checkers > maxConcurrency {
		s.Checkers = maxConcurrency
	}
	if s.TrashRetentionDays > 3650 {
		s.TrashRetentionDays = 3650
	}

	root := strings.TrimSpace(s.MountRoot)
	if root == "" {
		return nil
	}
	resolved := filepath.Clean(expandHome(root))
	if !filepath.IsAbs(resolved) {
		return fmt.Errorf("the Cloud Sync folder must be an absolute path")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("resolve home directory: %w", err)
	}
	// Streamed folders are mounted under this root, so it stays inside $HOME:
	// a mount point elsewhere is both a surprise and a way to shadow a system
	// directory the user can write to.
	if resolved != home && !strings.HasPrefix(resolved, home+string(os.PathSeparator)) {
		return fmt.Errorf("the Cloud Sync folder must be inside your home directory")
	}
	s.MountRoot = resolved
	return nil
}

func (m *Manager) validateSettings(s *Settings) error { return validateSettings(s) }

func (m *Manager) schedulePrune() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	m.pruneTimer = time.AfterFunc(trashPruneInterval, func() {
		days := m.store.snapshotSettings().TrashRetentionDays
		if days > 0 {
			m.store.pruneTrash(time.Now().AddDate(0, 0, -days).Unix())
		}
		m.schedulePrune()
	})
	m.mu.Unlock()
}

type folderIDParams struct {
	ID string `json:"id"`
	// Force is only honoured by syncNow: it overrides the delete guard after
	// the user has seen why a run was stopped and asked for it anyway.
	Force bool `json:"force"`
}

type remoteParams struct {
	Name string `json:"name"`
	// RemoveFolders acknowledges removal of folders that depend on the account.
	// Account removal requires it while dependent folders exist.
	RemoveFolders bool `json:"removeFolders"`
}

type updateRemoteParams struct {
	Name  string `json:"name"`
	Label string `json:"label"`
}

type browseParams struct {
	Remote string `json:"remote"`
	Path   string `json:"path"`
}

type createRemoteParams struct {
	Name       string          `json:"name"`
	Type       string          `json:"type"`
	Parameters json.RawMessage `json:"parameters"`
}

type resyncParams struct {
	ID   string `json:"id"`
	Side string `json:"side"`
}

type resolveParams struct {
	ID     string `json:"id"`
	Action string `json:"action"`
}

type bandwidthParams struct {
	Up   string `json:"up"`
	Down string `json:"down"`
}

func (m *Manager) handleGetState(json.RawMessage) (any, error) { return m.snapshot(), nil }

func (m *Manager) handleListProviders(json.RawMessage) (any, error) {
	providers, err := m.listProviders()
	if err != nil {
		return nil, err
	}
	return map[string]any{"providers": providers}, nil
}

func (m *Manager) handleListRemotes(json.RawMessage) (any, error) {
	m.refreshAccounts()
	m.mu.Lock()
	accounts := append([]Account{}, m.accounts...)
	m.mu.Unlock()
	return map[string]any{"accounts": accounts}, nil
}

func (m *Manager) handleAddRemote(params json.RawMessage) (any, error) {
	var p createRemoteParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.addRemote(p.Name, p.Type, decodeStringMap(p.Parameters)); err != nil {
		return nil, err
	}
	return m.snapshot(), nil
}

func (m *Manager) handleUpdateRemote(params json.RawMessage) (any, error) {
	var p updateRemoteParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.setAccountLabel(p.Name, p.Label); err != nil {
		return nil, err
	}
	return m.snapshot(), nil
}

func (m *Manager) handleRemoveRemote(params json.RawMessage) (any, error) {
	var p remoteParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.removeRemote(p.Name, p.RemoveFolders); err != nil {
		return nil, err
	}
	return m.snapshot(), nil
}

func (m *Manager) handleReconnectRemote(params json.RawMessage) (any, error) {
	var p createRemoteParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.reconnectRemote(p.Name, decodeStringMap(p.Parameters)); err != nil {
		return nil, err
	}
	return m.snapshot(), nil
}

// handleCheckRemote starts an account check in the background. Account health
// updates carry its result; the immediate response can precede completion.
func (m *Manager) handleCheckRemote(params json.RawMessage) (any, error) {
	var p remoteParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := validateRemoteName(p.Name); err != nil {
		return nil, err
	}
	if !m.accountExists(p.Name) {
		return nil, fmt.Errorf("no such account")
	}
	// Account probes run in the background because the server serializes calls per
	// method. A slow probe must not delay another account check. The account health
	// field carries the result.
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return nil, fmt.Errorf("cloud sync is shutting down")
	}
	m.tasks.Add(1)
	m.mu.Unlock()
	go func() {
		defer m.tasks.Done()
		_ = m.checkAccount(p.Name)
	}()
	return m.snapshot(), nil
}

func (m *Manager) handleTestRemote(params json.RawMessage) (any, error) {
	var p remoteParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.testRemote(p.Name); err != nil {
		return map[string]any{"ok": false, "error": firstLine(err.Error())}, nil
	}
	return map[string]any{"ok": true}, nil
}

func (m *Manager) handleAbout(params json.RawMessage) (any, error) {
	var p remoteParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := validateRemoteName(p.Name); err != nil {
		return nil, err
	}
	var about rcAbout
	if err := m.client.callTimeout("operations/about", map[string]any{"fs": p.Name + ":"}, &about, 20*time.Second); err != nil {
		return nil, err
	}
	return Quota{Total: about.Total, Used: about.Used, Free: about.Free, Trashed: about.Trashed}, nil
}

func (m *Manager) handleStartOAuth(params json.RawMessage) (any, error) {
	var p createRemoteParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.startOAuth(p.Name, p.Type, decodeStringMap(p.Parameters)); err != nil {
		return nil, err
	}
	return m.snapshot(), nil
}

func (m *Manager) handleCancelOAuth(json.RawMessage) (any, error) {
	m.cancelOAuth()
	return m.snapshot(), nil
}

func (m *Manager) handleBrowse(params json.RawMessage) (any, error) {
	var p browseParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	entries, err := m.browse(p.Remote, p.Path)
	if err != nil {
		return nil, err
	}
	dirs := make([]map[string]any, 0, len(entries))
	for _, entry := range entries {
		dirs = append(dirs, map[string]any{
			"name": entry.Name,
			"path": entry.Path,
		})
	}
	return map[string]any{"path": strings.Trim(p.Path, "/"), "entries": dirs}, nil
}

func (m *Manager) handleAddFolder(params json.RawMessage) (any, error) {
	var folder Folder
	if err := json.Unmarshal(params, &folder); err != nil {
		return nil, err
	}
	folder.ID = ""
	normalized, err := m.normalizeFolder(folder)
	if err != nil {
		return nil, err
	}
	if err := m.validateFolder(normalized); err != nil {
		return nil, err
	}
	if normalized.Mode == ModeStream {
		if err := os.MkdirAll(normalized.LocalPath, 0o700); err != nil {
			return nil, fmt.Errorf("create mount point: %w", err)
		}
	}
	if err := m.store.putFolder(normalized); err != nil {
		return nil, err
	}

	m.afterFolderChange(normalized)
	if normalized.Mode == ModeStream {
		if err := m.mountFolder(normalized.ID); err != nil {
			m.log.Warn("cloudsync could not mount new folder", "folder", normalized.ID, "err", err)
		}
	}
	m.broadcastNow()
	return m.snapshot(), nil
}

func (m *Manager) handleUpdateFolder(params json.RawMessage) (any, error) {
	var incoming Folder
	if err := json.Unmarshal(params, &incoming); err != nil {
		return nil, err
	}
	existing, ok := m.store.folder(incoming.ID)
	if !ok {
		return nil, fmt.Errorf("no such folder")
	}
	// Mode, remote and local path identify the pair and its bisync state. Changing
	// them requires a separate pair with its own baseline.
	incoming.Mode = existing.Mode
	incoming.Remote = existing.Remote
	incoming.RemotePath = existing.RemotePath
	incoming.LocalPath = existing.LocalPath
	incoming.ResyncDone = existing.ResyncDone
	incoming.CreatedUnix = existing.CreatedUnix

	normalized, err := m.normalizeFolder(incoming)
	if err != nil {
		return nil, err
	}
	if err := m.store.putFolder(normalized); err != nil {
		return nil, err
	}
	m.afterFolderChange(normalized)
	m.broadcastNow()
	return m.snapshot(), nil
}

func (m *Manager) handleRemoveFolder(params json.RawMessage) (any, error) {
	var p folderIDParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.removeFolderByID(p.ID); err != nil {
		return nil, err
	}
	m.broadcastNow()
	return m.snapshot(), nil
}

// removeFolderByID stops a pair and removes its configuration and runtime state.
// Teardown errors stop removal. Local files are retained.
func (m *Manager) removeFolderByID(id string) error {
	folder, ok := m.store.folder(id)
	if !ok {
		return fmt.Errorf("no such folder")
	}
	if err := m.teardownFolder(folder, true); err != nil {
		m.markFolderError(id, err)
		return err
	}
	if m.watcher != nil {
		m.watcher.unwatch(id)
	}

	if _, err := m.store.deleteFolder(id); err != nil {
		return err
	}
	m.mu.Lock()
	delete(m.statuses, id)
	delete(m.failures, id)
	if timer := m.timers[id]; timer != nil {
		timer.Stop()
		delete(m.timers, id)
	}
	kept := m.conflicts[:0]
	for _, c := range m.conflicts {
		if c.FolderID != id {
			kept = append(kept, c)
		}
	}
	m.conflicts = append([]Conflict{}, kept...)
	m.mu.Unlock()
	return nil
}

func (m *Manager) handleSyncNow(params json.RawMessage) (any, error) {
	var p folderIDParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if p.ID == "" {
		// Include each failed folder in the response so a partial Sync all failure
		// identifies the affected folders.
		var failed []string
		var lastErr error
		for _, folder := range m.store.snapshotFolders() {
			if folder.Mode == ModeStream || folder.Paused {
				continue
			}
			if err := m.startSync(folder.ID, syncOptions{Trigger: triggerManual, Force: p.Force}); err != nil {
				failed = append(failed, folder.displayName())
				lastErr = err
			}
		}
		if lastErr != nil {
			if len(failed) == 1 {
				return nil, fmt.Errorf("%s: %w", failed[0], lastErr)
			}
			return nil, fmt.Errorf("%d folders could not start (%s); the last reason was: %w", len(failed), strings.Join(failed, ", "), lastErr)
		}
		return m.snapshot(), nil
	}
	if err := m.startSync(p.ID, syncOptions{Trigger: triggerManual, Force: p.Force}); err != nil {
		return nil, err
	}
	return m.snapshot(), nil
}

// handleResync establishes (or re-establishes) a two-way baseline. The caller
// must say which side wins, because that is the decision only a human can make.
func (m *Manager) handleResync(params json.RawMessage) (any, error) {
	var p resyncParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	folder, ok := m.store.folder(p.ID)
	if !ok {
		return nil, fmt.Errorf("no such folder")
	}
	if folder.Mode != ModeTwoWay {
		return nil, fmt.Errorf("only two-way folders need a baseline")
	}
	mode := ""
	switch p.Side {
	case "local", "path1":
		mode = "path1"
	case "cloud", "path2":
		mode = "path2"
	case "newer":
		mode = "newer"
	default:
		return nil, fmt.Errorf("choose which side wins: this computer, the cloud, or the newer file")
	}
	if err := m.startSync(p.ID, syncOptions{Trigger: triggerManual, Resync: true, ResyncMode: mode}); err != nil {
		return nil, err
	}
	return m.snapshot(), nil
}

func (m *Manager) handleCancelJob(params json.RawMessage) (any, error) {
	var p folderIDParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.cancelSync(p.ID); err != nil {
		return nil, err
	}
	return m.snapshot(), nil
}

func (m *Manager) handlePauseFolder(params json.RawMessage) (any, error) {
	return m.setFolderPaused(params, true)
}

func (m *Manager) handleResumeFolder(params json.RawMessage) (any, error) {
	return m.setFolderPaused(params, false)
}

func (m *Manager) setFolderPaused(params json.RawMessage, paused bool) (any, error) {
	var p folderIDParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	folder, ok := m.store.folder(p.ID)
	if !ok {
		return nil, fmt.Errorf("no such folder")
	}
	if paused {
		if err := m.teardownFolder(folder, true); err != nil {
			m.markFolderError(folder.ID, err)
			m.broadcastNow()
			return nil, err
		}
	}
	folder.Paused = paused
	if err := m.store.putFolder(folder); err != nil {
		return nil, err
	}
	if !paused && folder.Mode == ModeStream {
		if err := m.mountFolder(folder.ID); err != nil {
			m.log.Warn("cloudsync could not mount resumed folder", "folder", folder.ID, "err", err)
		}
	}
	m.afterFolderChange(folder)
	m.broadcastNow()
	return m.snapshot(), nil
}

func (m *Manager) handlePauseAll(json.RawMessage) (any, error) { return m.setGlobalPaused(true) }

func (m *Manager) handleResumeAll(json.RawMessage) (any, error) { return m.setGlobalPaused(false) }

func (m *Manager) setGlobalPaused(paused bool) (any, error) {
	if paused {
		if err := m.teardownRunningFolders(); err != nil {
			m.broadcastNow()
			return nil, err
		}
	}
	settings := m.store.snapshotSettings()
	settings.Paused = paused
	if err := m.store.putSettings(settings); err != nil {
		return nil, err
	}
	m.syncWatchers()
	m.rescheduleAll()
	m.broadcastNow()
	return m.snapshot(), nil
}

func (m *Manager) teardownFolder(folder Folder, stopMount bool) error {
	var problems []string
	if err := m.cancelSync(folder.ID); err != nil {
		problems = append(problems, "stop sync: "+firstLine(err.Error()))
	}
	if stopMount && folder.Mode == ModeStream {
		if err := m.unmountFolder(folder.ID); err != nil {
			problems = append(problems, "unmount stream: "+firstLine(err.Error()))
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("%s: %s", folder.displayName(), strings.Join(problems, "; "))
	}
	return nil
}

func (m *Manager) teardownRunningFolders() error {
	var problems []string
	for _, folder := range m.store.snapshotFolders() {
		// Streamed folders have mounts rather than jobs. Global pause must release
		// those mounts separately.
		if err := m.teardownFolder(folder, true); err != nil {
			m.markFolderError(folder.ID, err)
			problems = append(problems, err.Error())
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("Cloud Sync was not paused because some syncs or mounts could not be stopped: %s", strings.Join(problems, "; "))
	}
	return nil
}

func (m *Manager) markFolderError(folderID string, err error) {
	m.mu.Lock()
	st := m.statusLocked(folderID)
	st.State = StateError
	st.LastError = firstLine(err.Error())
	m.mu.Unlock()
	m.log.Warn("cloudsync folder entered error state", "folder", folderID, "err", err)
}

func (m *Manager) runningFolderIDs() map[string]struct{} {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make(map[string]struct{}, len(m.jobs))
	for id := range m.jobs {
		out[id] = struct{}{}
	}
	return out
}

func (m *Manager) handleUpdateSettings(params json.RawMessage) (any, error) {
	current := m.store.snapshotSettings()
	if err := json.Unmarshal(params, &current); err != nil {
		return nil, err
	}
	if err := m.validateSettings(&current); err != nil {
		return nil, err
	}
	if err := m.store.putSettings(current); err != nil {
		return nil, err
	}
	_ = m.applyBandwidth(m.store.snapshotSettings())
	m.syncWatchers()
	m.rescheduleAll()
	m.broadcastNow()
	return m.snapshot(), nil
}

func (m *Manager) handleSetBandwidthLimit(params json.RawMessage) (any, error) {
	var p bandwidthParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	settings := m.store.snapshotSettings()
	settings.BandwidthUp = strings.TrimSpace(p.Up)
	settings.BandwidthDown = strings.TrimSpace(p.Down)
	if err := m.store.putSettings(settings); err != nil {
		return nil, err
	}
	// The limit is saved for daemon startup even if applying it to the running
	// daemon fails. Report that failure to the caller.
	applyErr := m.applyBandwidth(settings)
	m.broadcastNow()
	if applyErr != nil {
		return nil, fmt.Errorf("the limit was saved but could not be applied right now: %w", applyErr)
	}
	return m.snapshot(), nil
}

func (m *Manager) handleGetHistory(json.RawMessage) (any, error) {
	return map[string]any{"history": m.store.snapshotHistory()}, nil
}

func (m *Manager) handleGetConflicts(json.RawMessage) (any, error) {
	if err := m.rescanAllConflicts(); err != nil {
		return nil, err
	}
	m.mu.Lock()
	conflicts := append([]Conflict{}, m.conflicts...)
	m.mu.Unlock()
	return map[string]any{"conflicts": conflicts}, nil
}

func (m *Manager) handleResolveConflict(params json.RawMessage) (any, error) {
	var p resolveParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.resolveConflict(p.ID, p.Action); err != nil {
		return nil, err
	}
	return m.snapshot(), nil
}

func (m *Manager) handleMount(params json.RawMessage) (any, error) {
	var p folderIDParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.mountFolder(p.ID); err != nil {
		return nil, err
	}
	return m.snapshot(), nil
}

func (m *Manager) handleUnmount(params json.RawMessage) (any, error) {
	var p folderIDParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	if err := m.unmountFolder(p.ID); err != nil {
		return nil, err
	}
	return m.snapshot(), nil
}

func (m *Manager) handleEmptyTrash(params json.RawMessage) (any, error) {
	var p folderIDParams
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, err
	}
	folders := m.store.snapshotFolders()
	if p.ID != "" {
		folder, ok := m.store.folder(p.ID)
		if !ok {
			return nil, fmt.Errorf("no such folder")
		}
		folders = []Folder{folder}
	}
	var unpurged []string
	for _, folder := range folders {
		if err := os.RemoveAll(m.store.localTrash(folder.ID)); err != nil {
			return nil, fmt.Errorf("empty local recycle bin: %w", err)
		}
		// The cloud-side bin is best-effort: the remote may be offline, and a
		// failure there must not block clearing local space. It is reported
		// rather than hidden, though — otherwise the remote bin keeps consuming
		// the user's quota while the operation claims success.
		if err := m.client.callTimeout("operations/purge",
			map[string]any{"fs": folder.remoteTrash(), "remote": ""}, nil, 60*time.Second); err != nil {
			m.log.Warn("cloudsync could not purge cloud recycle bin", "folder", folder.ID, "err", err)
			unpurged = append(unpurged, folder.displayName())
		}
	}
	m.broadcastNow()
	if len(unpurged) > 0 {
		return nil, fmt.Errorf("local recycle bin emptied, but the cloud copy could not be reached for: %s", strings.Join(unpurged, ", "))
	}
	return m.snapshot(), nil
}

func (m *Manager) handleRestartDaemon(json.RawMessage) (any, error) {
	if err := m.daemon.ensure(); err != nil {
		return nil, err
	}
	return m.snapshot(), nil
}

func (m *Manager) afterFolderChange(folder Folder) {
	m.syncWatchers()
	m.scheduleFolder(folder)
	// Only folder counts change here. Reuse cached account metadata to avoid
	// network probes on folder edits.
	m.recountAccountFolders()
}

func (m *Manager) recountAccountFolders() {
	counts := map[string]int{}
	for _, f := range m.store.snapshotFolders() {
		counts[f.Remote]++
	}
	m.mu.Lock()
	for i := range m.accounts {
		m.accounts[i].Folders = counts[m.accounts[i].Name]
	}
	m.mu.Unlock()
}
