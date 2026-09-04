package cloudsync

import (
	"time"
)

// Trigger names recorded in history so the Activity view can say why a run
// happened.
const (
	triggerManual   = "manual"
	triggerSchedule = "schedule"
	triggerWatch    = "realtime"
	triggerStartup  = "startup"
)

const (
	// minInterval floors user-chosen periods; anything faster is what the
	// real-time watcher is for.
	minInterval = 5 * time.Minute
	// maxBackoff caps the retry delay after repeated failures so a folder that
	// recovers is not stuck waiting hours.
	maxBackoff = 30 * time.Minute
	// startupDelay lets the shell finish coming up before the first sync.
	startupDelay = 20 * time.Second
)

// scheduleFolder arms (or disarms) the folder's next scheduled run. It is
// called after every state change that could affect timing: config edits,
// pause/resume, and job completion.
func (m *Manager) scheduleFolder(folder Folder) {
	m.mu.Lock()
	if timer, ok := m.timers[folder.ID]; ok && timer != nil {
		timer.Stop()
		delete(m.timers, folder.ID)
	}
	if m.closed {
		m.mu.Unlock()
		return
	}
	m.mu.Unlock()

	settings := m.store.snapshotSettings()
	if folder.Mode == ModeStream || folder.Paused || settings.Paused || folder.IntervalSeconds <= 0 {
		m.mu.Lock()
		m.statusLocked(folder.ID).NextSyncUnix = 0
		m.mu.Unlock()
		return
	}
	if folder.Mode.NeedsResync() && !folder.ResyncDone {
		m.mu.Lock()
		m.statusLocked(folder.ID).NextSyncUnix = 0
		m.mu.Unlock()
		return
	}

	delay := m.nextDelay(folder)
	id := folder.ID

	m.mu.Lock()
	m.statusLocked(id).NextSyncUnix = time.Now().Add(delay).Unix()
	m.timers[id] = time.AfterFunc(delay, func() {
		m.runScheduled(id)
	})
	m.mu.Unlock()
}

func (m *Manager) nextDelay(folder Folder) time.Duration {
	interval := time.Duration(folder.IntervalSeconds) * time.Second
	if interval < minInterval {
		interval = minInterval
	}

	m.mu.Lock()
	failures := m.failures[folder.ID]
	m.mu.Unlock()
	if failures <= 0 {
		return interval
	}

	delay := interval
	for i := 0; i < failures && delay < maxBackoff; i++ {
		delay *= 2
	}
	if delay > maxBackoff {
		delay = maxBackoff
	}
	return delay
}

func (m *Manager) runScheduled(folderID string) {
	folder, ok := m.store.folder(folderID)
	if !ok {
		return
	}
	if err := m.startSync(folderID, syncOptions{Trigger: triggerSchedule}); err != nil {
		m.noteStartFailure(folderID, triggerSchedule, err)
		m.noteFailure(folderID)
		m.scheduleFolder(folder)
		return
	}
	m.noteSuccess(folderID)
	// A started job re-schedules itself from finishJob; only a run that never
	// started needs re-arming here.
}

func (m *Manager) noteFailure(folderID string) {
	m.mu.Lock()
	m.failures[folderID]++
	m.mu.Unlock()
}

func (m *Manager) noteSuccess(folderID string) {
	m.mu.Lock()
	delete(m.failures, folderID)
	m.mu.Unlock()
}

func (m *Manager) rescheduleAll() {
	for _, folder := range m.store.snapshotFolders() {
		m.scheduleFolder(folder)
	}
}

// scheduleStartupSweep queues the first run for every scheduled folder shortly
// after the shell starts, so a machine that was off overnight catches up
// without the user asking.
func (m *Manager) scheduleStartupSweep() {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return
	}
	m.startupTimer = time.AfterFunc(startupDelay, func() {
		settings := m.store.snapshotSettings()
		if settings.Paused {
			return
		}
		for _, folder := range m.store.snapshotFolders() {
			if folder.Paused || folder.Mode == ModeStream || folder.IntervalSeconds <= 0 {
				continue
			}
			if folder.Mode.NeedsResync() && !folder.ResyncDone {
				continue
			}
			if err := m.startSync(folder.ID, syncOptions{Trigger: triggerStartup}); err != nil {
				m.noteStartFailure(folder.ID, triggerStartup, err)
			}
		}
	})
	m.mu.Unlock()
}
