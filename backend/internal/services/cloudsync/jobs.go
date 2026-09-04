package cloudsync

import (
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

const (
	// progressInterval limits control calls while keeping progress updates
	// available to the bar widget.
	progressInterval = 750 * time.Millisecond
	// recentInterval throttles the completed-transfers feed, which is a whole
	// separate rc round trip and does not need per-frame freshness.
	recentInterval = 3 * time.Second
	// jobCallTimeout bounds the short control calls that start and inspect
	// jobs. The sync itself is async and unbounded.
	jobCallTimeout = 20 * time.Second
)

// statusPollLimit bounds consecutive job/status failures. Finished jobs can
// expire from rclone state; retrying indefinitely would leave the folder stuck
// on Syncing.
const statusPollLimit = 8

type activeJob struct {
	FolderID    string
	RCJobID     int64
	Group       string
	Trigger     string
	StartedUnix int64
	Resync      bool
	// Generation distinguishes daemon instances because rclone can reuse job IDs
	// after restart.
	Generation uint64
	// StatusFailures counts consecutive job/status errors. Guarded by mu.
	StatusFailures int
}

// statsGroup is the rclone stats group for a folder, so each folder's progress
// can be read back independently of everything else running.
func statsGroup(folderID string) string { return "vgs-" + folderID }

type syncOptions struct {
	Trigger    string
	Resync     bool
	ResyncMode string
	// Force overrides bisync's delete guard. Only set it when the user has
	// already approved the deletion (resolving a conflict), never for
	// scheduled or watcher-triggered runs.
	Force bool
}

// startSync launches a sync for one folder unless it is already running,
// paused, or (for two-way) still missing its baseline.
func (m *Manager) startSync(folderID string, opts syncOptions) error {
	folder, ok := m.store.folder(folderID)
	if !ok {
		return fmt.Errorf("no such folder")
	}
	if folder.Mode == ModeStream {
		return fmt.Errorf("streamed folders do not run syncs; they are mounted on demand")
	}

	// Configuration-level refusals are reported before the daemon check, so the
	// user sees the actionable reason ("this needs a baseline") rather than an
	// incidental one ("rclone is not running").
	settings := m.store.snapshotSettings()
	if settings.Paused && opts.Trigger != triggerManual {
		return nil
	}
	if folder.Paused && opts.Trigger != triggerManual {
		return nil
	}
	if folder.Mode.NeedsResync() && !folder.ResyncDone && !opts.Resync {
		return fmt.Errorf("this folder needs its first two-way baseline before it can sync")
	}
	if !m.daemon.running() {
		return fmt.Errorf("rclone control daemon is not running")
	}

	m.mu.Lock()
	// A timer that had already fired when Close() stopped it would otherwise
	// launch a brand-new sync during shutdown, which is never polled (the
	// progress loop refuses to start) and never cancelled.
	if m.closed {
		m.mu.Unlock()
		return fmt.Errorf("cloud sync is shutting down")
	}
	if _, running := m.jobs[folderID]; running {
		m.mu.Unlock()
		return nil // A running job picks up recent writes.
	}
	generation := m.daemonGeneration
	m.mu.Unlock()

	group := statsGroup(folderID)
	// Clear the previous run's counters so progress starts from zero rather
	// than continuing a lifetime total.
	_ = m.client.callTimeout("core/stats-reset", map[string]any{"group": group}, nil, 5*time.Second)

	params, err := m.buildSyncParams(folder, settings, group, opts)
	if err != nil {
		return err
	}

	endpoint := "sync/sync"
	if folder.Mode == ModeTwoWay {
		endpoint = "sync/bisync"
	}

	var job rcAsyncJob
	if err := m.client.callTimeout(endpoint, params, &job, jobCallTimeout); err != nil {
		m.recordFailure(folder, opts.Trigger, err.Error())
		return err
	}

	now := nowUnix()
	m.mu.Lock()
	// The daemon can stop between the control call and job registration. Reject an
	// outdated generation so the interrupted-job cleanup cannot miss a late
	// insertion.
	if m.closed || m.daemonGeneration != generation {
		m.mu.Unlock()
		return fmt.Errorf("the sync engine restarted; try again")
	}
	m.jobs[folderID] = &activeJob{
		FolderID:    folderID,
		RCJobID:     job.JobID,
		Group:       group,
		Trigger:     opts.Trigger,
		StartedUnix: now,
		Resync:      opts.Resync,
		Generation:  generation,
	}
	st := m.statusLocked(folderID)
	st.State = StateSyncing
	st.LastError = ""
	st.Bytes, st.TotalBytes, st.Speed, st.ETASeconds = 0, 0, 0, 0
	st.Transferring = nil
	m.mu.Unlock()

	m.ensureProgressLoop()
	m.broadcastNow()
	return nil
}

// buildSyncParams configures backup directories for deleted and overwritten
// files. Backup and restore set MaxDelete; two-way requests resilient recovery
// and keeps bisync's deletion guard unless Force is set.
func (m *Manager) buildSyncParams(folder Folder, settings Settings, group string, opts syncOptions) (map[string]any, error) {
	config := map[string]any{
		"Transfers": settings.Transfers,
		"Checkers":  settings.Checkers,
	}
	filter := map[string]any{}
	if len(folder.Excludes) > 0 {
		filter["ExcludeRule"] = folder.Excludes
	}

	params := map[string]any{
		"_async": true,
		"_group": group,
	}

	switch folder.Mode {
	case ModeBackup, ModeRestore:
		src, dst := folder.LocalPath, folder.remoteFs()
		backupDir := folder.remoteTrash()
		if folder.Mode == ModeRestore {
			src, dst = folder.remoteFs(), folder.LocalPath
			backupDir = m.store.localTrash(folder.ID)
		}
		// Keep deleted and overwritten files in VGS trash until retention pruning or
		// explicit emptying removes them.
		config["BackupDir"] = backupDir
		if folder.MaxDelete >= 0 {
			config["MaxDelete"] = folder.MaxDelete
		}
		params["srcFs"] = src
		params["dstFs"] = dst
		params["createEmptySrcDirs"] = true

	case ModeTwoWay:
		conflictResolve := folder.ConflictResolve
		if conflictResolve == "" {
			conflictResolve = "none"
		}
		params["path1"] = folder.LocalPath
		params["path2"] = folder.remoteFs()
		params["workdir"] = m.store.bisyncWorkdir(folder.ID)
		params["createEmptySrcDirs"] = true
		params["backupDir1"] = m.store.localTrash(folder.ID)
		params["backupDir2"] = folder.remoteTrash()
		params["conflictResolve"] = conflictResolve
		params["conflictSuffix"] = conflictSuffix
		// resilient + recover let an interrupted or transiently-failing run
		// pick itself back up instead of demanding a manual --resync.
		params["resilient"] = true
		params["recover"] = true
		params["maxLock"] = "15m"
		// bisync aborts when a run would delete more than half of a side. That
		// guard is right for an unattended sync, but a user resolving a
		// conflict has already decided; without the override, resolving on a
		// small folder is refused outright.
		if opts.Force {
			params["force"] = true
		}
		if opts.Resync {
			params["resync"] = true
			mode := opts.ResyncMode
			if mode == "" {
				mode = "path1"
			}
			params["resyncMode"] = mode
		}

	default:
		return nil, fmt.Errorf("unsupported sync mode %q", folder.Mode)
	}

	params["_config"] = config
	if len(filter) > 0 {
		params["_filter"] = filter
	}
	return params, nil
}

// cancelSync requests cancellation of a running rclone job.
func (m *Manager) cancelSync(folderID string) error {
	m.mu.Lock()
	job := m.jobs[folderID]
	m.mu.Unlock()
	if job == nil {
		return nil
	}
	if err := m.client.callTimeout("job/stop", map[string]any{"jobid": job.RCJobID}, nil, 10*time.Second); err != nil {
		return err
	}
	return nil
}

// ensureProgressLoop starts the polling goroutine if it is not already running.
// One loop serves every active job.
func (m *Manager) ensureProgressLoop() {
	m.mu.Lock()
	if m.progressRunning || m.closed {
		m.mu.Unlock()
		return
	}
	m.progressRunning = true
	m.mu.Unlock()

	go m.progressLoop()
}

func (m *Manager) progressLoop() {
	ticker := time.NewTicker(progressInterval)
	defer ticker.Stop()
	lastRecent := time.Time{}

	for range ticker.C {
		m.mu.Lock()
		if m.closed {
			m.progressRunning = false
			m.mu.Unlock()
			return
		}
		jobs := make([]*activeJob, 0, len(m.jobs))
		for _, job := range m.jobs {
			jobs = append(jobs, job)
		}
		// Check for jobs and clear progressRunning under the same lock. A job inserted
		// between these operations could otherwise observe an active poller just
		// before it exits and remain unpolled.
		if len(jobs) == 0 {
			m.progressRunning = false
			m.mu.Unlock()
			m.resetGlobalStats()
			m.broadcastNow()
			return
		}
		m.mu.Unlock()

		for _, job := range jobs {
			m.pollJob(job)
		}
		if time.Since(lastRecent) >= recentInterval {
			m.refreshRecent()
			lastRecent = time.Now()
		}
		m.recomputeGlobal()
		m.broadcastThrottled()
	}
}

func (m *Manager) pollJob(job *activeJob) {
	folder, ok := m.store.folder(job.FolderID)
	if !ok {
		m.finishJob(job, false, "folder was removed", rcStats{})
		return
	}

	var stats rcStats
	if err := m.client.callTimeout("core/stats", map[string]any{"group": job.Group}, &stats, 5*time.Second); err != nil {
		// A stats hiccup is not a job failure; job/status below is the
		// authority on whether the run is still alive.
		m.log.Debug("cloudsync stats poll failed", "folder", job.FolderID, "err", err)
	} else {
		m.applyStats(folder, job, stats)
	}

	var status rcJobStatus
	if err := m.client.callTimeout("job/status", map[string]any{"jobid": job.RCJobID}, &status, 5*time.Second); err != nil {
		// End the job after repeated status failures so expired rclone jobs cannot
		// leave the folder stuck on Syncing.
		m.mu.Lock()
		job.StatusFailures++
		failures := job.StatusFailures
		m.mu.Unlock()
		if failures < statusPollLimit {
			m.log.Debug("cloudsync job status poll failed", "folder", job.FolderID, "attempt", failures, "err", err)
			return
		}
		m.log.Warn("cloudsync giving up on a job whose status cannot be read",
			"folder", job.FolderID, "attempts", failures, "err", err)
		m.finishJob(job, false, "the sync stopped responding and was interrupted", stats)
		return
	}
	m.mu.Lock()
	job.StatusFailures = 0
	m.mu.Unlock()
	if !status.Finished {
		return
	}
	m.finishJob(job, status.Success, status.Error, stats)
}

func (m *Manager) applyStats(folder Folder, job *activeJob, stats rcStats) {
	transferring := make([]Transfer, 0, len(stats.Transferring))
	for _, t := range stats.Transferring {
		transferring = append(transferring, Transfer{
			Name:       filepath.Base(t.Name),
			FolderID:   folder.ID,
			FolderName: folder.displayName(),
			Direction:  transferDirection(folder, t),
			Size:       t.Size,
			Bytes:      t.Bytes,
			Percentage: t.Percentage,
			Speed:      t.Speed,
			SpeedAvg:   t.SpeedAvg,
			ETASeconds: t.ETA,
		})
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	st := m.statusLocked(folder.ID)
	st.State = StateSyncing
	st.Bytes = stats.Bytes
	st.TotalBytes = stats.TotalBytes
	st.Speed = stats.Speed
	st.ETASeconds = stats.ETA
	st.Transfers = stats.Transfers
	st.Checks = stats.Checks
	st.Errors = stats.Errors
	st.Transferring = transferring
	_ = job
}

// transferDirection infers upload vs download. rclone reports the source and
// destination fs per transfer, and a leading "/" means the local filesystem.
func transferDirection(folder Folder, t rcTransferring) string {
	switch folder.Mode {
	case ModeBackup:
		return "up"
	case ModeRestore:
		return "down"
	}
	if strings.HasPrefix(t.SrcFs, "/") {
		return "up"
	}
	if strings.HasPrefix(t.DstFs, "/") {
		return "down"
	}
	return "up"
}

func (m *Manager) finishJob(job *activeJob, success bool, errMsg string, stats rcStats) {
	folder, exists := m.store.folder(job.FolderID)
	now := nowUnix()

	m.mu.Lock()
	delete(m.jobs, job.FolderID)
	if !exists {
		// statusLocked would re-create the record for a folder that was just
		// removed, leaving an entry nothing ever reclaims (snapshot iterates
		// configured folders, so it is invisible too).
		delete(m.statuses, job.FolderID)
		delete(m.failures, job.FolderID)
		m.mu.Unlock()
		m.broadcastNow()
		return
	}
	st := m.statusLocked(job.FolderID)
	st.Transferring = nil
	st.Speed = 0
	st.ETASeconds = 0
	st.LastSyncUnix = now
	if success {
		st.State = StateIdle
		st.LastError = ""
		st.LastSuccessUnix = now
	} else {
		st.State = StateError
		st.LastError = explainSyncError(errMsg)
	}
	if folder.Paused {
		st.State = StatePaused
	}
	m.mu.Unlock()

	// A successful resync establishes the two-way baseline; without persisting
	// it the folder would demand another manual resync every run.
	if success && job.Resync && folder.Mode == ModeTwoWay && !folder.ResyncDone {
		folder.ResyncDone = true
		if err := m.store.putFolder(folder); err != nil {
			m.log.Warn("cloudsync could not persist resync baseline", "folder", folder.ID, "err", err)
		}
	}

	entry := HistoryEntry{
		ID:           fmt.Sprintf("%s-%d", folder.ID, job.StartedUnix),
		FolderID:     folder.ID,
		FolderName:   folder.displayName(),
		Mode:         folder.Mode,
		Trigger:      job.Trigger,
		StartedUnix:  job.StartedUnix,
		FinishedUnix: now,
		Success:      success,
		Error:        firstLine(errMsg),
		Bytes:        stats.Bytes,
		Transfers:    stats.Transfers,
		Checks:       stats.Checks,
		Errors:       stats.Errors,
	}
	m.store.appendHistory(entry)

	if folder.Mode == ModeTwoWay {
		m.rescanConflicts(folder)
	}
	m.scheduleFolder(folder)
	m.broadcastNow()
}

// noteStartFailure records a triggered run that could not start. Scheduled runs
// and conflict-resolution syncs need the failure in folder state and history
// even when no caller is waiting.
func (m *Manager) noteStartFailure(folderID, trigger string, err error) {
	if err == nil {
		return
	}
	m.log.Warn("cloudsync run did not start", "folder", folderID, "trigger", trigger, "err", err)
	if _, ok := m.store.folder(folderID); !ok {
		return
	}
	m.mu.Lock()
	st := m.statusLocked(folderID)
	// A run already in flight is the more truthful state; do not overwrite it.
	if st.State != StateSyncing {
		st.State = StateError
		st.LastError = explainSyncError(err.Error())
	}
	m.mu.Unlock()
	m.broadcastNow()
}

func (m *Manager) recordFailure(folder Folder, trigger, errMsg string) {
	now := nowUnix()
	m.mu.Lock()
	st := m.statusLocked(folder.ID)
	st.State = StateError
	st.LastError = explainSyncError(errMsg)
	st.LastSyncUnix = now
	m.mu.Unlock()

	m.store.appendHistory(HistoryEntry{
		ID:           fmt.Sprintf("%s-%d", folder.ID, now),
		FolderID:     folder.ID,
		FolderName:   folder.displayName(),
		Mode:         folder.Mode,
		Trigger:      trigger,
		StartedUnix:  now,
		FinishedUnix: now,
		Success:      false,
		Error:        firstLine(errMsg),
	})
	m.broadcastNow()
}

func (m *Manager) refreshRecent() {
	var list rcTransferredList
	if err := m.client.callTimeout("core/transferred", nil, &list, 5*time.Second); err != nil {
		return
	}
	byGroup := map[string]Folder{}
	for _, f := range m.store.snapshotFolders() {
		byGroup[statsGroup(f.ID)] = f
	}

	recent := make([]RecentFile, 0, len(list.Transferred))
	for i := len(list.Transferred) - 1; i >= 0; i-- {
		t := list.Transferred[i]
		if t.Checked {
			continue // checks are not user-visible file movements
		}
		folder, known := byGroup[t.Group]
		if !known {
			continue
		}
		recent = append(recent, RecentFile{
			Name:          filepath.Base(t.Name),
			FolderID:      folder.ID,
			FolderName:    folder.displayName(),
			Direction:     transferDirection(folder, rcTransferring{SrcFs: t.SrcFs, DstFs: t.DstFs}),
			Size:          t.Size,
			Error:         firstLine(t.Error),
			CompletedUnix: parseRCTime(t.CompletedAt),
		})
		if len(recent) >= 60 {
			break
		}
	}

	m.mu.Lock()
	m.recent = recent
	m.mu.Unlock()
}

func (m *Manager) recomputeGlobal() {
	m.mu.Lock()
	defer m.mu.Unlock()

	var g GlobalStats
	var slowestETA float64
	for id := range m.jobs {
		st := m.statusLocked(id)
		g.Speed += st.Speed
		g.Bytes += st.Bytes
		g.TotalBytes += st.TotalBytes
		g.Transfers += st.Transfers
		g.Errors += st.Errors
		if st.ETASeconds > slowestETA {
			slowestETA = st.ETASeconds
		}
		if g.ActiveFolder == "" {
			if folder, ok := m.store.folder(id); ok {
				g.ActiveFolder = folder.displayName()
			}
		}
	}
	g.ETASeconds = slowestETA
	m.global = g
}

func (m *Manager) resetGlobalStats() {
	m.mu.Lock()
	m.global = GlobalStats{}
	m.mu.Unlock()
}

// statusLocked returns the mutable status record for a folder. Caller holds mu.
func (m *Manager) statusLocked(folderID string) *FolderStatus {
	st, ok := m.statuses[folderID]
	if !ok {
		st = &FolderStatus{ID: folderID, State: StateIdle}
		m.statuses[folderID] = st
	}
	return st
}

// explainSyncError adds user actions to recognized rclone errors and passes
// other messages through.
func explainSyncError(msg string) string {
	line := firstLine(msg)
	if line == "" {
		return ""
	}
	if strings.Contains(strings.ToLower(line), "too many deletes") {
		return "This sync would delete more than half the files on one side, so it was stopped. Check the folder, then use Sync anyway if that is what you meant."
	}
	return line
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	if idx := strings.IndexByte(s, '\n'); idx >= 0 {
		s = s[:idx]
	}
	return strings.TrimSpace(s)
}

func parseRCTime(value string) int64 {
	if value == "" {
		return 0
	}
	t, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return 0
	}
	if t.IsZero() {
		return 0
	}
	return t.Unix()
}

func nowUnix() int64 { return time.Now().Unix() }
