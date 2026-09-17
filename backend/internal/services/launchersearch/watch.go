package launchersearch

import (
	"context"
	"log/slog"
	"os"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"

	"vshell/backend/internal/recovery"
)

// settleDelay collects a burst of changes, such as an unpacked archive, into
// one re-listing of each directory it touched. Tests shorten it.
var settleDelay = 300 * time.Millisecond

// Only a name appearing or disappearing changes the index; writes to a file
// do not.
const watchMask = unix.IN_CREATE | unix.IN_DELETE | unix.IN_MOVED_FROM | unix.IN_MOVED_TO |
	unix.IN_ONLYDIR | unix.IN_DONT_FOLLOW | unix.IN_EXCL_UNLINK

type watcher struct {
	fd   int
	file *os.File
	log  *slog.Logger

	// writer is held for a whole delta, so one delta at a time writes the index.
	writer sync.Mutex

	mu      sync.Mutex
	pending map[int32]bool
	timer   *time.Timer
	closed  bool
}

func newWatcher(log *slog.Logger) (*watcher, error) {
	fd, err := unix.InotifyInit1(unix.IN_CLOEXEC | unix.IN_NONBLOCK)
	if err != nil {
		return nil, err
	}
	return &watcher{
		fd:      fd,
		file:    os.NewFile(uintptr(fd), "vgs-launcher-search-inotify"),
		log:     log,
		pending: map[int32]bool{},
	}, nil
}

func (w *watcher) add(path string) (int32, error) {
	wd, err := unix.InotifyAddWatch(w.fd, path, watchMask)
	return int32(wd), err
}

func (w *watcher) remove(wd int32) {
	_, _ = unix.InotifyRmWatch(w.fd, uint32(wd))
}

func (w *watcher) close() {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	w.closed = true
	if w.timer != nil {
		w.timer.Stop()
	}
	w.mu.Unlock()
	// Closing the file unblocks the reader and releases every watch.
	_ = w.file.Close()
}

// watchChanges reads the index's events until its watcher is closed. It starts
// once the walk that built the index is done; the kernel holds what arrived
// during the walk.
func (ix *index) watchChanges() {
	w := ix.watch
	buf := make([]byte, 64*1024)
	for {
		n, err := w.file.Read(buf)
		if err != nil {
			w.mu.Lock()
			closed := w.closed
			w.mu.Unlock()
			if !closed {
				w.log.Warn("launcher search watcher stopped", "err", err)
				ix.degraded.Store(true)
			}
			return
		}
		recovery.Run(w.log, "launchersearch.watchEvents", func() { ix.noteEvents(buf[:n]) })
	}
}

func (ix *index) noteEvents(buf []byte) {
	w := ix.watch
	w.mu.Lock()
	defer w.mu.Unlock()
	for offset := 0; offset+unix.SizeofInotifyEvent <= len(buf); {
		raw := (*unix.InotifyEvent)(unsafe.Pointer(&buf[offset]))
		offset += unix.SizeofInotifyEvent + int(raw.Len)
		if raw.Mask&unix.IN_Q_OVERFLOW != 0 {
			ix.degraded.Store(true)
			continue
		}
		if raw.Mask&unix.IN_IGNORED != 0 {
			continue
		}
		w.pending[raw.Wd] = true
	}
	if len(w.pending) > 0 && w.timer == nil && !w.closed {
		w.timer = recovery.AfterFunc(settleDelay, w.log, "launchersearch.applyChanges", ix.applyChanges)
	}
}

// applyChanges re-lists every directory that reported a change and brings its
// entries in the index up to date. Every removal in the batch lands before any
// new directory is walked: a directory moved within the roots keeps its inode,
// and the kernel hands its new watch the descriptor the removal releases.
func (ix *index) applyChanges() {
	w := ix.watch
	w.writer.Lock()
	defer w.writer.Unlock()

	w.mu.Lock()
	w.timer = nil
	if w.closed {
		w.mu.Unlock()
		return
	}
	dirty := w.pending
	w.pending = map[int32]bool{}
	w.mu.Unlock()

	var jobs []dirJob
	for wd := range dirty {
		ix.mu.RLock()
		positions := append([]int32(nil), ix.byWd[wd]...)
		ix.mu.RUnlock()
		for _, pos := range positions {
			jobs = append(jobs, ix.relistJob(pos))
		}
	}

	// Listing re-adds each directory's own watch, which returns the descriptor
	// it already has.
	listings := make([]listing, 0, len(jobs))
	for _, job := range jobs {
		listings = append(listings, ix.list(job))
	}

	var walks []dirJob
	ix.mu.Lock()
	for _, l := range listings {
		walks = ix.reconcile(l, walks)
	}
	ix.mu.Unlock()

	if err := ix.walk(context.Background(), walks); err != nil {
		// walk returns only its context's error, and this context has none.
		panic("launchersearch: delta walk failed: " + err.Error())
	}
}

// relistJob is the job that lists an indexed directory again.
func (ix *index) relistJob(pos int32) dirJob {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	root := pos
	for ix.entries[root].parent >= 0 {
		root = ix.entries[root].parent
	}
	return dirJob{pos: pos, path: ix.path(pos), dev: ix.rootDev[root]}
}

// reconcile applies one fresh listing to the directory it lists: entries gone
// from disk are removed with everything under them, new ones are added, and
// new directories are queued to be walked. The caller holds mu.
func (ix *index) reconcile(l listing, walks []dirJob) []dirJob {
	pos := l.job.pos
	node, ok := ix.dirs[pos]
	if !l.read {
		// Unreadable now: the directory is gone, and its parent's own listing
		// removes it, or it failed for a reason that says nothing about its
		// children.
		return walks
	}
	if !ok {
		// Removed earlier in this batch along with an ancestor.
		return walks
	}
	existing := make(map[string]int32, len(node.children))
	for _, c := range node.children {
		existing[string(ix.name(c))] = c
	}
	var kept []int32
	for _, c := range l.children {
		if old, found := existing[c.name]; found {
			delete(existing, c.name)
			if (ix.entries[old].flags&flagDir != 0) == c.isDir {
				kept = append(kept, old)
				continue
			}
			ix.remove(old)
		}
		added := ix.add(pos, c.name, c.isDir)
		// add appended to node.children; the list is rebuilt below.
		kept = append(kept, added)
		if c.isDir {
			walks = append(walks, dirJob{pos: added, path: c.path, dev: l.job.dev})
		}
	}
	for _, old := range existing {
		ix.remove(old)
	}
	node.children = kept
	return walks
}

// remove marks an entry and everything under it dead and releases the watches
// of the directories among them. The caller holds mu.
func (ix *index) remove(pos int32) {
	e := &ix.entries[pos]
	if e.flags&flagDead != 0 {
		return
	}
	e.flags |= flagDead
	ix.dead++
	node, ok := ix.dirs[pos]
	if !ok {
		return
	}
	delete(ix.dirs, pos)
	for _, c := range node.children {
		ix.remove(c)
	}
	if node.wd < 0 {
		return
	}
	positions := ix.byWd[node.wd]
	for i, p := range positions {
		if p == pos {
			positions = append(positions[:i], positions[i+1:]...)
			break
		}
	}
	if len(positions) > 0 {
		// The same directory is indexed under another path, as a bind mount
		// shows it, and still needs its watch.
		ix.byWd[node.wd] = positions
		return
	}
	delete(ix.byWd, node.wd)
	if ix.watch != nil {
		ix.watch.remove(node.wd)
	}
}
