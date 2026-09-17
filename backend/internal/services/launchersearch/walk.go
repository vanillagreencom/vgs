package launchersearch

import (
	"context"
	"errors"
	"os"
	"runtime"

	"golang.org/x/sys/unix"

	"vshell/backend/internal/recovery"
)

// dirJob is one directory still to list. dev is its root's device, which a
// config that ignores mounts requires every directory under the root to share.
type dirJob struct {
	pos  int32
	path string
	dev  uint64
}

type child struct {
	name  string
	path  string
	isDir bool
	id    fileID
}

type listing struct {
	job dirJob
	wd  int32
	// read is false when the directory could not be opened, so its children
	// are unknown rather than gone.
	read     bool
	children []child
}

// walkWorkers bounds how many directories one walk lists at once. It leaves
// half the machine's CPUs to the desktop that is drawing while the walk runs.
func walkWorkers() int {
	return max(1, runtime.NumCPU()/2)
}

// list watches one directory and then reads it, in that order: an entry created
// between the two is then either in the listing or reported by the watch. Only
// regular files and directories are returned, without following symlinks, and
// an ignored entry, or a directory on another device when the config ignores
// mounts, is left out.
func (ix *index) list(job dirJob) listing {
	out := listing{job: job, wd: -1}
	if ix.watch != nil && !ix.unwatched.Load() {
		if ix.watches.Load() >= ix.watchBudget {
			ix.giveUpWatches("the index reached its share of the inotify watch limit")
		} else {
			wd, err := ix.watch.add(job.path)
			switch {
			case err == nil:
				out.wd = wd
			case errors.Is(err, unix.ENOSPC):
				ix.giveUpWatches("the user's inotify watch limit is exhausted")
			}
		}
	}
	dir, err := os.Open(job.path)
	if err != nil {
		return out
	}
	defer dir.Close()
	entries, err := dir.ReadDir(-1)
	out.read = err == nil
	prefix := job.path + "/"
	if job.path == "/" {
		prefix = "/"
	}
	for _, de := range entries {
		mode := de.Type()
		if !mode.IsDir() && !mode.IsRegular() {
			continue
		}
		name := de.Name()
		path := prefix + name
		if ix.cfg.ignores.ignored(path, name) {
			continue
		}
		c := child{name: name, path: path, isDir: mode.IsDir()}
		if c.isDir {
			var st unix.Stat_t
			if unix.Lstat(path, &st) != nil || st.Mode&unix.S_IFMT != unix.S_IFDIR {
				continue
			}
			if ix.cfg.ignoreMounts && st.Dev != job.dev {
				continue
			}
			c.id = fileID{dev: st.Dev, ino: st.Ino}
		}
		out.children = append(out.children, c)
	}
	return out
}

// walk lists every directory under starts and adds what it finds to the index,
// one directory's children at a time, so a search running beside a delta walk
// sees each directory either whole or not at all.
func (ix *index) walk(ctx context.Context, starts []dirJob) error {
	jobs := make(chan dirJob)
	results := make(chan listing)
	stop := make(chan struct{})
	defer close(stop)
	for i := 0; i < walkWorkers(); i++ {
		go func() {
			for job := range jobs {
				// A panicking listing still answers, as an unread directory, so
				// the walk does not wait for it forever.
				result := listing{job: job, wd: -1}
				recovery.Run(ix.log, "launchersearch.list", func() { result = ix.list(job) })
				select {
				case results <- result:
				case <-stop:
					return
				}
			}
		}()
	}
	defer close(jobs)

	queue := append([]dirJob(nil), starts...)
	inflight := 0
	for len(queue) > 0 || inflight > 0 {
		var send chan dirJob
		var next dirJob
		if len(queue) > 0 {
			send = jobs
			next = queue[len(queue)-1]
		}
		select {
		case send <- next:
			queue = queue[:len(queue)-1]
			inflight++
		case result := <-results:
			inflight--
			queue = ix.record(result, queue)
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return nil
}

// record adds one listing to the index and queues its subdirectories.
func (ix *index) record(result listing, queue []dirJob) []dirJob {
	ix.mu.Lock()
	defer ix.mu.Unlock()
	node := ix.dirs[result.job.pos]
	if node == nil {
		// Removed by a later listing in the same batch. Its watch is released
		// unless another position holds it.
		if result.wd >= 0 && len(ix.byWd[result.wd]) == 0 && ix.watch != nil {
			ix.watch.remove(result.wd)
		}
		return queue
	}
	ix.bindWatch(result.job.pos, node, result.wd)
	if !result.read {
		return queue
	}
	for _, c := range result.children {
		pos := ix.add(result.job.pos, c.name, c.isDir, c.id)
		if c.isDir {
			queue = append(queue, dirJob{pos: pos, path: c.path, dev: result.job.dev})
		}
	}
	return queue
}
