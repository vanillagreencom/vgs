package cloudsync

import (
	"fmt"
	"os"
	"os/exec"
	"time"
)

// mountCallTimeout bounds mount/unmount control calls. Mounting contacts the
// remote, so it is more generous than a plain status call.
const mountCallTimeout = 45 * time.Second

// fuseAvailable reports whether stream (on-demand) folders can work at all.
func fuseAvailable() bool {
	for _, binary := range []string{"fusermount3", "fusermount"} {
		if _, err := exec.LookPath(binary); err == nil {
			return true
		}
	}
	return false
}

// mountFolder exposes a remote as an on-demand FUSE mount. Nothing is copied to
// disk: files download when opened and live in rclone's VFS cache.
func (m *Manager) mountFolder(folderID string) error {
	folder, ok := m.store.folder(folderID)
	if !ok {
		return fmt.Errorf("no such folder")
	}
	if folder.Mode != ModeStream {
		return fmt.Errorf("only streamed folders are mounted")
	}
	if !m.canMount {
		return fmt.Errorf("FUSE is not available; install fuse3 to stream cloud folders")
	}
	if !m.daemon.running() {
		return fmt.Errorf("rclone control daemon is not running")
	}

	if err := os.MkdirAll(folder.LocalPath, 0o700); err != nil {
		return fmt.Errorf("create mount point: %w", err)
	}
	// A non-empty mount point usually means a stale mount or leftover files;
	// mounting over them would hide the user's data.
	//
	// A ReadDir *error* is not an all-clear: the likeliest cause on a mount
	// point is a stale FUSE handle (EIO/ENOTCONN), which is precisely the case
	// this check exists to catch. Previously it was gated on err == nil and so
	// skipped exactly then.
	entries, readErr := os.ReadDir(folder.LocalPath)
	switch {
	case readErr != nil:
		if m.isMounted(folder.LocalPath) {
			return nil
		}
		return fmt.Errorf("cannot check whether %s is empty (%v); it may be a stale mount — try disconnecting it first", folder.LocalPath, firstLine(readErr.Error()))
	case len(entries) > 0:
		if !m.isMounted(folder.LocalPath) {
			return fmt.Errorf("%s is not empty; empty it before streaming into it", folder.LocalPath)
		}
		return nil
	}

	m.mu.Lock()
	m.statusLocked(folder.ID).State = StateMounting
	m.mu.Unlock()
	m.broadcastNow()

	params := map[string]any{
		"fs":         folder.remoteFs(),
		"mountPoint": folder.LocalPath,
		"vfsOpt": map[string]any{
			// "full" gives normal file semantics (seek, rewrite, offline reads
			// of anything already fetched) at the cost of cache disk usage.
			"CacheMode": "full",
			// Backends that support change notification push remote edits
			// through immediately; the rest fall back to this poll.
			"PollInterval": "1m",
			"DirCacheTime": "5m",
		},
		"mountOpt": map[string]any{
			"AllowOther": false,
			"VolumeName": folder.displayName(),
		},
	}
	if err := m.client.callTimeout("mount/mount", params, nil, mountCallTimeout); err != nil {
		m.mu.Lock()
		st := m.statusLocked(folder.ID)
		st.State = StateError
		st.LastError = firstLine(err.Error())
		m.mu.Unlock()
		m.broadcastNow()
		return err
	}

	m.mu.Lock()
	st := m.statusLocked(folder.ID)
	st.State = StateMounted
	st.Mounted = true
	st.MountPoint = folder.LocalPath
	st.LastError = ""
	m.mu.Unlock()
	m.broadcastNow()
	return nil
}

// unmountFolder releases a streamed folder's mount point.
func (m *Manager) unmountFolder(folderID string) error {
	folder, ok := m.store.folder(folderID)
	if !ok {
		return fmt.Errorf("no such folder")
	}
	err := m.client.callTimeout("mount/unmount", map[string]any{"mountPoint": folder.LocalPath}, nil, mountCallTimeout)

	m.mu.Lock()
	st := m.statusLocked(folder.ID)
	st.Mounted = false
	st.MountPoint = ""
	if err != nil {
		st.State = StateError
		st.LastError = firstLine(err.Error())
	} else {
		st.State = StateUnmounted
		st.LastError = ""
	}
	m.mu.Unlock()
	m.broadcastNow()
	return err
}

// isMounted asks rclone whether it currently owns this mount point.
func (m *Manager) isMounted(mountPoint string) bool {
	var mounts rcMounts
	if err := m.client.callTimeout("mount/listmounts", nil, &mounts, 5*time.Second); err != nil {
		return false
	}
	for _, mp := range mounts.MountPoints {
		if mp.MountPoint == mountPoint {
			return true
		}
	}
	return false
}

// refreshMountStates reconciles reported mount status with reality, so a mount
// that rclone dropped does not keep showing as connected.
func (m *Manager) refreshMountStates() {
	var mounts rcMounts
	if err := m.client.callTimeout("mount/listmounts", nil, &mounts, 5*time.Second); err != nil {
		// Returning silently leaves every streamed folder reporting the mount
		// state it had before, so a dropped mount keeps showing "Streaming".
		m.log.Warn("cloudsync could not list mounts", "err", err)
		return
	}
	active := map[string]bool{}
	for _, mp := range mounts.MountPoints {
		active[mp.MountPoint] = true
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	for _, folder := range m.store.snapshotFolders() {
		if folder.Mode != ModeStream {
			continue
		}
		st := m.statusLocked(folder.ID)
		st.Mounted = active[folder.LocalPath]
		if st.Mounted {
			st.State = StateMounted
			st.MountPoint = folder.LocalPath
		} else if st.State != StateMounting && st.State != StateError {
			st.State = StateUnmounted
			st.MountPoint = ""
		}
	}
}

// mountConfiguredFolders brings up every streamed folder. Called once the
// daemon is ready so mounts survive an rclone restart.
func (m *Manager) mountConfiguredFolders() {
	settings := m.store.snapshotSettings()
	for _, folder := range m.store.snapshotFolders() {
		if folder.Mode != ModeStream || folder.Paused || settings.Paused {
			continue
		}
		if err := m.mountFolder(folder.ID); err != nil {
			m.log.Warn("cloudsync could not mount streamed folder", "folder", folder.ID, "err", err)
		}
	}
}

// unmountAll releases every mount on shutdown. Leaving them behind would strand
// a dead mount point in the user's home directory.
func (m *Manager) unmountAll() {
	if !m.client.ready() {
		return
	}
	_ = m.client.callTimeout("mount/unmountall", nil, nil, 15*time.Second)
}
