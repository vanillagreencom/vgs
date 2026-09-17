package launchersearch

import (
	"context"
	"log/slog"
	"os"
	"sync"
	"syscall"
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
	file *os.File
	// raw issues every call on the inotify descriptor. Close waits for a call
	// in progress and every later call fails, so a call can never reach
	// another instance that reused the descriptor's number.
	raw syscall.RawConn
	log *slog.Logger

	// writer is held for a whole delta, so one delta at a time writes the index.
	writer sync.Mutex

	mu sync.Mutex
	// pending holds the watches that reported a change; dropped, the watches
	// the kernel ended on its own.
	pending map[int32]bool
	dropped map[int32]bool
	timer   *time.Timer
	closed  bool
}

func newWatcher(log *slog.Logger) (*watcher, error) {
	fd, err := unix.InotifyInit1(unix.IN_CLOEXEC | unix.IN_NONBLOCK)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), "vgs-launcher-search-inotify")
	raw, err := file.SyscallConn()
	if err != nil {
		file.Close()
		return nil, err
	}
	return &watcher{
		file:    file,
		raw:     raw,
		log:     log,
		pending: map[int32]bool{},
		dropped: map[int32]bool{},
	}, nil
}

func (w *watcher) add(path string) (int32, error) {
	wd, err := -1, error(nil)
	if cerr := w.raw.Control(func(fd uintptr) {
		wd, err = unix.InotifyAddWatch(int(fd), path, watchMask)
	}); cerr != nil {
		return -1, cerr
	}
	return int32(wd), err
}

func (w *watcher) remove(wd int32) {
	_ = w.raw.Control(func(fd uintptr) {
		_, _ = unix.InotifyRmWatch(int(fd), uint32(wd))
	})
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
				ix.degrade("the inotify event reader stopped", "err", err)
			}
			return
		}
		recovery.Run(ix.log, "launchersearch.watchEvents", func() { ix.noteEvents(buf[:n]) })
	}
}

func (ix *index) noteEvents(buf []byte) {
	w := ix.watch
	w.mu.Lock()
	defer w.mu.Unlock()
	for offset := 0; offset+unix.SizeofInotifyEvent <= len(buf); {
		raw := (*unix.InotifyEvent)(unsafe.Pointer(&buf[offset]))
		offset += unix.SizeofInotifyEvent + int(raw.Len)
		switch {
		case raw.Mask&unix.IN_Q_OVERFLOW != 0:
			ix.degrade("the kernel's inotify event queue overflowed")
		case raw.Mask&unix.IN_UNMOUNT != 0:
			// The kernel ends every watch on the file system; a later mount at
			// the same place sends nothing.
			ix.degrade("a file system under the search roots was unmounted", "path", ix.watchedPath(raw.Wd))
		case raw.Mask&unix.IN_IGNORED != 0:
			w.dropped[raw.Wd] = true
		default:
			w.pending[raw.Wd] = true
		}
	}
	if len(w.pending)+len(w.dropped) > 0 && w.timer == nil && !w.closed {
		w.timer = recovery.AfterFunc(settleDelay, ix.log, "launchersearch.applyChanges", ix.applyChanges)
	}
}

// watchedPath names a directory a watch reports, for a log line.
func (ix *index) watchedPath(wd int32) string {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	if positions := ix.byWd[wd]; len(positions) > 0 {
		return ix.path(positions[0])
	}
	return ""
}

// applyChanges re-lists every directory that reported a change and brings its
// entries in the index up to date. Adding a watch on a directory that already
// has one returns that same descriptor, so every removal in the batch lands
// before any new directory is walked: a directory moved within the roots is
// then watched afresh under its new position instead of keeping a descriptor
// the removal is about to release.
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
	dirty, dropped := w.pending, w.dropped
	w.pending, w.dropped = map[int32]bool{}, map[int32]bool{}
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
	ix.checkDropped(dropped)
}

// checkDropped handles the watches the kernel ended on its own. One whose
// directory the batch already removed needs nothing. Any other directory is
// listed again, which watches it afresh and brings its entries up to date, or,
// when it is gone, re-lists its parent so the parent's listing removes it. A
// root that is gone leaves nothing to watch it through.
func (ix *index) checkDropped(dropped map[int32]bool) {
	var jobs []dirJob
	for wd := range dropped {
		ix.mu.RLock()
		var lost []int32
		for _, pos := range ix.byWd[wd] {
			if node := ix.dirs[pos]; node != nil && node.wd == wd {
				lost = append(lost, pos)
			}
		}
		ix.mu.RUnlock()
		for _, pos := range lost {
			jobs = append(jobs, ix.relistJob(pos))
		}
	}
	if len(jobs) == 0 {
		return
	}
	listings := make([]listing, 0, len(jobs))
	for _, job := range jobs {
		listings = append(listings, ix.list(job))
	}
	var walks []dirJob
	var parents []int32
	ix.mu.Lock()
	for _, l := range listings {
		if l.read {
			walks = ix.reconcile(l, walks)
			continue
		}
		parent := ix.entries[l.job.pos].parent
		if parent < 0 || ix.dirs[parent] == nil || ix.dirs[parent].wd < 0 {
			ix.mu.Unlock()
			ix.degrade("a directory's watch ended and it can no longer be listed", "path", l.job.path)
			ix.mu.Lock()
			continue
		}
		parents = append(parents, ix.dirs[parent].wd)
	}
	ix.mu.Unlock()
	if err := ix.walk(context.Background(), walks); err != nil {
		panic("launchersearch: delta walk failed: " + err.Error())
	}
	if len(parents) == 0 {
		return
	}
	w := ix.watch
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, wd := range parents {
		w.pending[wd] = true
	}
	if w.timer == nil && !w.closed {
		w.timer = recovery.AfterFunc(settleDelay, ix.log, "launchersearch.applyChanges", ix.applyChanges)
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
// new directories are queued to be walked. A directory removed and made again
// under the same name keeps its entry here; the kernel ends the old one's
// watch, and checkDropped lists it afresh. The caller holds mu.
func (ix *index) reconcile(l listing, walks []dirJob) []dirJob {
	pos := l.job.pos
	node, ok := ix.dirs[pos]
	if !ok {
		// Removed earlier in this batch along with an ancestor.
		return walks
	}
	if !l.read {
		// Unreadable now: the directory is gone, and its parent's own listing
		// removes it, or it failed for a reason that says nothing about its
		// children.
		return walks
	}
	ix.bindWatch(pos, node, l.wd)
	existing := make(map[string]int32, len(node.children))
	for _, c := range node.children {
		existing[string(ix.name(c))] = c
	}
	var kept []int32
	for _, c := range l.children {
		if old, found := existing[c.name]; found {
			delete(existing, c.name)
			if (ix.dirs[old] != nil) == c.isDir {
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
	for _, c := range node.children {
		ix.remove(c)
	}
	if node.wd >= 0 {
		ix.unbindWatch(pos, node)
	}
	delete(ix.dirs, pos)
}
