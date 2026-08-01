package cloudsync

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// watchDebounce is how long writes must be quiet before a real-time folder
// syncs. Long enough that saving a large file or unpacking an archive produces
// one sync instead of dozens. A variable so tests can shorten it.
var watchDebounce = 5 * time.Second

// watchMask covers the events that mean "the tree changed in a way the cloud
// should learn about". IN_MODIFY is deliberately excluded in favour of
// IN_CLOSE_WRITE: syncing a file that is still being written is worse than
// syncing it a moment later.
const watchMask = unix.IN_CREATE | unix.IN_DELETE | unix.IN_DELETE_SELF |
	unix.IN_MOVED_FROM | unix.IN_MOVED_TO | unix.IN_MOVE_SELF |
	unix.IN_CLOSE_WRITE | unix.IN_EXCL_UNLINK

// watcher is a recursive inotify watcher shared by every real-time folder.
// rclone has no filesystem watching of its own, so this is what makes
// "sync as I work" possible.
type watcher struct {
	file    *os.File
	fd      int
	onDirty func(folderID string)
	// onDegraded fires when real-time watching stops working mid-session, so
	// the manager can push the reason into state. Without it the UI kept
	// reporting a folder as watched after its watches had silently died.
	onDegraded func()
	log        debugLogger

	mu       sync.Mutex
	byWd     map[int32]string
	byPath   map[string]int32
	roots    map[string]string // folder ID -> root path
	degraded map[string]string // folder ID -> reason
	timers   map[string]*time.Timer
	closed   bool
}

// debugLogger is the small slice of slog the watcher needs, so tests can pass a
// no-op.
type debugLogger interface {
	Debug(msg string, args ...any)
	Warn(msg string, args ...any)
}

func newWatcher(log debugLogger, onDirty func(folderID string)) (*watcher, error) {
	fd, err := unix.InotifyInit1(unix.IN_CLOEXEC | unix.IN_NONBLOCK)
	if err != nil {
		return nil, err
	}
	w := &watcher{
		file:     os.NewFile(uintptr(fd), "vgs-cloudsync-inotify"),
		fd:       fd,
		onDirty:  onDirty,
		log:      log,
		byWd:     map[int32]string{},
		byPath:   map[string]int32{},
		roots:    map[string]string{},
		degraded: map[string]string{},
		timers:   map[string]*time.Timer{},
	}
	go w.readLoop()
	return w, nil
}

// watch starts watching a folder's tree. A partially-watched tree is reported
// as degraded rather than pretending real-time works.
func (w *watcher) watch(folderID, root string) {
	w.unwatch(folderID)

	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	w.roots[folderID] = root
	delete(w.degraded, folderID)
	w.mu.Unlock()

	added, err := w.addTree(folderID, root)
	if err != nil {
		w.mu.Lock()
		w.degraded[folderID] = err.Error()
		w.mu.Unlock()
		w.log.Warn("cloudsync real-time watch degraded", "folder", folderID, "err", err)
		return
	}
	w.log.Debug("cloudsync watching tree", "folder", folderID, "directories", added)
}

// addTree registers a watch on root and every directory beneath it.
func (w *watcher) addTree(folderID, root string) (int, error) {
	count := 0
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			// Unreadable subdirectories are skipped, not fatal: a sync folder
			// can legitimately contain something this user cannot traverse.
			if os.IsPermission(err) {
				return nil
			}
			return err
		}
		if !info.IsDir() || isIgnoredPath(path) {
			if info.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if addErr := w.addWatch(folderID, path); addErr != nil {
			return addErr
		}
		count++
		return nil
	})
	return count, err
}

func (w *watcher) addWatch(folderID, path string) error {
	wd, err := unix.InotifyAddWatch(w.fd, path, watchMask)
	if err != nil {
		if errors.Is(err, unix.ENOSPC) {
			return errors.New("the system inotify watch limit is exhausted; falling back to scheduled syncs")
		}
		if errors.Is(err, unix.ENOENT) || errors.Is(err, unix.EACCES) {
			return nil
		}
		return err
	}
	w.mu.Lock()
	w.byWd[int32(wd)] = path
	w.byPath[path] = int32(wd)
	w.mu.Unlock()
	_ = folderID
	return nil
}

// unwatch removes every watch belonging to a folder.
func (w *watcher) unwatch(folderID string) {
	w.mu.Lock()
	root, ok := w.roots[folderID]
	delete(w.roots, folderID)
	delete(w.degraded, folderID)
	if timer := w.timers[folderID]; timer != nil {
		timer.Stop()
		delete(w.timers, folderID)
	}
	if !ok {
		w.mu.Unlock()
		return
	}
	var drop []string
	for path := range w.byPath {
		if path == root || strings.HasPrefix(path, root+string(filepath.Separator)) {
			drop = append(drop, path)
		}
	}
	wds := make([]int32, 0, len(drop))
	for _, path := range drop {
		wd := w.byPath[path]
		wds = append(wds, wd)
		delete(w.byPath, path)
		delete(w.byWd, wd)
	}
	closed := w.closed
	w.mu.Unlock()

	if closed {
		return
	}
	for _, wd := range wds {
		_, _ = unix.InotifyRmWatch(w.fd, uint32(wd))
	}
}

// watchState reports whether a folder is watched and why it is not, if so.
func (w *watcher) watchState(folderID string) (bool, string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	reason := w.degraded[folderID]
	_, watching := w.roots[folderID]
	return watching && reason == "", reason
}

// readLoop decodes inotify events until the watcher is closed.
func (w *watcher) readLoop() {
	buf := make([]byte, 64*1024)
	for {
		n, err := w.file.Read(buf)
		if err != nil {
			if errors.Is(err, os.ErrClosed) {
				return
			}
			w.mu.Lock()
			closed := w.closed
			w.mu.Unlock()
			if closed {
				return
			}
			// The loop is dead for the life of the process: every watched
			// folder has stopped syncing on write, so all of them are marked
			// rather than left reporting "watched" and "Up to date".
			w.log.Warn("cloudsync watcher read failed", "err", err)
			w.degrade("", "real-time watching stopped: "+firstLine(err.Error()))
			return
		}
		w.handleEvents(buf[:n])
	}
}

func (w *watcher) handleEvents(buf []byte) {
	offset := 0
	for offset+unix.SizeofInotifyEvent <= len(buf) {
		raw := (*unix.InotifyEvent)(unsafe.Pointer(&buf[offset]))
		nameLen := int(raw.Len)
		nameStart := offset + unix.SizeofInotifyEvent
		name := ""
		if nameLen > 0 && nameStart+nameLen <= len(buf) {
			name = strings.TrimRight(string(buf[nameStart:nameStart+nameLen]), "\x00")
		}
		offset = nameStart + nameLen

		w.mu.Lock()
		dir, known := w.byWd[raw.Wd]
		w.mu.Unlock()
		if !known {
			continue
		}
		full := dir
		if name != "" {
			full = filepath.Join(dir, name)
		}
		if isIgnoredPath(full) {
			continue
		}

		folderID := w.folderFor(full)
		if folderID == "" {
			continue
		}
		// A new subdirectory needs its own watch, and anything created inside
		// it before we get there is covered by the sync that follows.
		if raw.Mask&unix.IN_ISDIR != 0 && raw.Mask&(unix.IN_CREATE|unix.IN_MOVED_TO) != 0 {
			if err := w.addWatch(folderID, full); err != nil {
				// Hitting max_user_watches mid-session is exactly when this
				// matters, and it is the case the architecture doc promises is
				// reported rather than silently ignored.
				w.degrade(folderID, err.Error())
			}
		}
		w.markDirty(folderID)
	}
}

// degrade records why real-time watching is not working for one folder, or for
// every watched folder when folderID is empty, and notifies the manager.
func (w *watcher) degrade(folderID, reason string) {
	w.mu.Lock()
	changed := false
	if folderID == "" {
		for id := range w.roots {
			if w.degraded[id] != reason {
				w.degraded[id] = reason
				changed = true
			}
		}
	} else if w.degraded[folderID] != reason {
		w.degraded[folderID] = reason
		changed = true
	}
	notify := w.onDegraded
	w.mu.Unlock()

	if changed && notify != nil {
		notify()
	}
}

// folderFor maps a path back to the folder that owns it.
func (w *watcher) folderFor(path string) string {
	w.mu.Lock()
	defer w.mu.Unlock()
	best := ""
	bestLen := 0
	for id, root := range w.roots {
		if path == root || strings.HasPrefix(path, root+string(filepath.Separator)) {
			if len(root) > bestLen {
				best, bestLen = id, len(root)
			}
		}
	}
	return best
}

// markDirty (re)arms the folder's debounce timer.
func (w *watcher) markDirty(folderID string) {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	if timer, ok := w.timers[folderID]; ok && timer != nil {
		timer.Reset(watchDebounce)
		w.mu.Unlock()
		return
	}
	w.timers[folderID] = time.AfterFunc(watchDebounce, func() {
		w.mu.Lock()
		delete(w.timers, folderID)
		closed := w.closed
		w.mu.Unlock()
		if closed {
			return
		}
		if w.onDirty != nil {
			w.onDirty(folderID)
		}
	})
	w.mu.Unlock()
}

func (w *watcher) close() {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	w.closed = true
	for _, timer := range w.timers {
		if timer != nil {
			timer.Stop()
		}
	}
	w.timers = map[string]*time.Timer{}
	w.roots = map[string]string{}
	w.byWd = map[int32]string{}
	w.byPath = map[string]int32{}
	w.mu.Unlock()

	// Closing the file unblocks readLoop and releases every watch with it.
	_ = w.file.Close()
}

// isIgnoredPath filters out churn that should never trigger a sync: our own
// trash and bisync bookkeeping, and rclone's in-progress temp files.
func isIgnoredPath(path string) bool {
	base := filepath.Base(path)
	switch {
	case base == ".vgs-trash", base == ".rclone-bisync":
		return true
	case strings.HasSuffix(base, ".partial"),
		strings.HasSuffix(base, ".rclonelink.tmp"),
		strings.HasPrefix(base, ".~tmp~"),
		strings.HasPrefix(base, ".goutputstream-"):
		return true
	}
	return strings.Contains(path, string(filepath.Separator)+".vgs-trash"+string(filepath.Separator))
}

// syncWatchers brings the watcher's set of watched trees in line with the
// current folder configuration.
func (m *Manager) syncWatchers() {
	if m.watcher == nil {
		return
	}
	settings := m.store.snapshotSettings()
	for _, folder := range m.store.snapshotFolders() {
		wantWatch := folder.RealTime &&
			!folder.Paused &&
			!settings.Paused &&
			folder.Mode != ModeStream &&
			(!folder.Mode.NeedsResync() || folder.ResyncDone)

		if wantWatch {
			m.watcher.watch(folder.ID, folder.LocalPath)
		} else {
			m.watcher.unwatch(folder.ID)
		}

		watching, reason := m.watcher.watchState(folder.ID)
		m.mu.Lock()
		st := m.statusLocked(folder.ID)
		st.Watching = watching
		st.WatchDegraded = reason
		m.mu.Unlock()
	}
}

// onWatchDirty is the watcher's callback: a debounced tree change wants a sync.
func (m *Manager) onWatchDirty(folderID string) {
	if err := m.startSync(folderID, syncOptions{Trigger: triggerWatch}); err != nil {
		m.noteStartFailure(folderID, triggerWatch, err)
	}
}
