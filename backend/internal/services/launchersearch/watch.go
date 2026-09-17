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
	// pending holds the watches to re-list, true for one the kernel ended.
	pending map[int32]bool
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
			// Ended by the kernel, or by the index releasing it, in which case
			// no position maps it any more and the batch finds nothing to do.
			w.pending[raw.Wd] = true
		default:
			// Queued for a re-list, keeping a kernel end already recorded.
			w.pending[raw.Wd] = w.pending[raw.Wd]
		}
	}
	if len(w.pending) > 0 && w.timer == nil && !w.closed {
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

// applyChanges re-lists every directory that reported a change, or whose
// watch the kernel ended, and brings its entries in the index up to date.
// Listing a directory watches it, which gives an ended watch a new descriptor.
// Adding a watch on a directory that already has one returns that same
// descriptor, so every removal in the batch lands before any new directory is
// walked: a directory moved within the roots is then watched afresh under its
// new position instead of keeping a descriptor the removal is about to release.
func (ix *index) applyChanges() {
	w := ix.watch
	w.writer.Lock()
	defer w.writer.Unlock()
	defer func() {
		if r := recover(); r != nil {
			// The rest of the batch is lost; only a fresh walk restores it.
			ix.degrade("a change batch failed", "panic", r)
			panic(r)
		}
	}()

	w.mu.Lock()
	w.timer = nil
	if w.closed {
		w.mu.Unlock()
		return
	}
	pending := w.pending
	w.pending = map[int32]bool{}
	w.mu.Unlock()

	var jobs []dirJob
	ended := map[int32]int32{}
	for wd, byKernel := range pending {
		ix.mu.RLock()
		positions := append([]int32(nil), ix.byWd[wd]...)
		ix.mu.RUnlock()
		for _, pos := range positions {
			jobs = append(jobs, ix.relistJob(pos))
			if byKernel {
				ended[pos] = wd
			}
		}
	}

	listings := make([]listing, 0, len(jobs))
	for _, job := range jobs {
		listings = append(listings, ix.list(job))
	}

	var walks []dirJob
	var lost []string
	ix.mu.Lock()
	for _, l := range listings {
		walks = ix.reconcile(l, walks)
	}
	// A directory whose watch ended, that no listing in the batch removed and
	// that could not be listed again, reports nothing from now on.
	for _, l := range listings {
		wd, byKernel := ended[l.job.pos]
		if node := ix.dirs[l.job.pos]; byKernel && !l.read && node != nil && node.wd == wd {
			lost = append(lost, l.job.path)
		}
	}
	ix.mu.Unlock()
	for _, path := range lost {
		ix.degrade("a directory's watch ended and it can no longer be listed", "path", path)
	}

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
// new directories are queued to be walked. A directory under an indexed name
// with another identity is a new directory. The caller holds mu.
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
			if node := ix.dirs[old]; (node != nil) == c.isDir && (node == nil || node.id == c.id) {
				kept = append(kept, old)
				continue
			}
			ix.remove(old)
		}
		added := ix.add(pos, c.name, c.isDir, c.id)
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
