package launchersearch

import (
	"context"
	"errors"
	"os"
	"runtime"

	"golang.org/x/sys/unix"
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
	if ix.watch != nil {
		wd, err := ix.watch.add(job.path)
		switch {
		case err == nil:
			out.wd = wd
		case errors.Is(err, unix.ENOSPC):
			ix.degraded.Store(true)
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
		if mode.IsDir() && ix.cfg.ignoreMounts {
			var st unix.Stat_t
			if unix.Lstat(path, &st) != nil || st.Dev != job.dev {
				continue
			}
		}
		out.children = append(out.children, child{name: name, path: path, isDir: mode.IsDir()})
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
				result := ix.list(job)
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
	if result.wd >= 0 {
		ix.dirs[result.job.pos].wd = result.wd
		ix.byWd[result.wd] = append(ix.byWd[result.wd], result.job.pos)
	}
	for _, c := range result.children {
		pos := ix.add(result.job.pos, c.name, c.isDir)
		if c.isDir {
			queue = append(queue, dirJob{pos: pos, path: c.path, dev: result.job.dev})
		}
	}
	return queue
}
