package cloudsync

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"strings"
)

const maxPersistedIntervalSeconds = 366 * 24 * 60 * 60

func (f Folder) remoteFs() string {
	clean := strings.Trim(strings.TrimSpace(f.RemotePath), "/")
	if clean == "" {
		return f.Remote + ":"
	}
	return f.Remote + ":" + clean
}

func (f Folder) displayName() string {
	if strings.TrimSpace(f.Name) != "" {
		return f.Name
	}
	if f.LocalPath != "" {
		return filepath.Base(f.LocalPath)
	}
	return f.remoteFs()
}

// remoteTrash places the remote recycle bin outside this folder's synced tree so
// this pair does not sync its own backups.
func (f Folder) remoteTrash() string {
	base := strings.Trim(strings.TrimSpace(f.RemotePath), "/")
	if base == "" {
		return f.Remote + ":.vgs-trash/" + f.ID
	}
	return f.Remote + ":" + path.Join(path.Dir(base), ".vgs-trash", f.ID)
}

func newFolderID() string {
	buf := make([]byte, 8)
	if _, err := rand.Read(buf); err != nil {
		return fmt.Sprintf("folder-%d", len(buf))
	}
	return hex.EncodeToString(buf)
}

// normalizeFolder fills defaults and canonicalizes paths. It does not consult
// other folders; validateFolder does that.
func (m *Manager) normalizeFolder(f Folder) (Folder, error) {
	f.Remote = strings.TrimSuffix(strings.TrimSpace(f.Remote), ":")
	remotePath, err := cleanRemotePath(f.RemotePath)
	if err != nil {
		return f, err
	}
	f.RemotePath = remotePath
	f.Name = strings.TrimSpace(f.Name)

	if f.Remote == "" {
		return f, fmt.Errorf("choose a cloud account")
	}
	// A folder's remote must be a configured account name, never a raw rclone
	// connection string. rclone accepts on-the-fly backends of the form
	// ":sftp,host=…:path", so an unvalidated Remote would let a folder sync to
	// a host that was never configured and never appears in Accounts.
	if err := validateRemoteName(f.Remote); err != nil {
		return f, err
	}
	if !f.Mode.Valid() {
		return f, fmt.Errorf("choose how this folder should sync")
	}
	if f.ID == "" {
		f.ID = newFolderID()
	}
	if f.CreatedUnix == 0 {
		f.CreatedUnix = nowUnix()
	}
	if f.MaxDelete == 0 {
		f.MaxDelete = -1
	}
	if f.Excludes == nil {
		f.Excludes = []string{}
	}

	local, err := m.resolveLocalPath(f)
	if err != nil {
		return f, err
	}
	f.LocalPath = local

	if f.Name == "" {
		f.Name = filepath.Base(local)
	}
	// Stream folders are mounted, never scheduled or watched.
	if f.Mode == ModeStream {
		f.IntervalSeconds = 0
		f.RealTime = false
	}
	if f.Mode != ModeTwoWay {
		f.ResyncDone = true
	}
	return f, nil
}

// resolveLocalPath returns the folder's local directory. Stream folders live
// under the mount root and are managed by us; the other modes use the path the
// user picked.
func (m *Manager) resolveLocalPath(f Folder) (string, error) {
	if f.Mode == ModeStream {
		root := strings.TrimSpace(m.store.snapshotSettings().MountRoot)
		if root == "" {
			root = m.store.mountRoot
		}
		name := f.Name
		if name == "" {
			name = f.Remote
			if f.RemotePath != "" {
				name = f.Remote + "-" + strings.ReplaceAll(f.RemotePath, "/", "-")
			}
		}
		return filepath.Join(expandHome(root), sanitizeDirName(name)), nil
	}

	local := expandHome(strings.TrimSpace(f.LocalPath))
	if local == "" {
		return "", fmt.Errorf("choose a folder on this computer")
	}
	if !filepath.IsAbs(local) {
		return "", fmt.Errorf("the local folder must be an absolute path")
	}
	return filepath.Clean(local), nil
}

// validateFolder rejects home and filesystem roots and overlapping configured
// pairs to prevent competing sync jobs.
func (m *Manager) validateFolder(f Folder) error {
	home, err := os.UserHomeDir()
	if err == nil {
		if f.LocalPath == filepath.Clean(home) {
			return fmt.Errorf("syncing your entire home directory is not supported; pick a folder inside it")
		}
	}
	if f.LocalPath == "/" || f.LocalPath == "" {
		return fmt.Errorf("pick a folder, not the filesystem root")
	}

	for _, other := range m.store.snapshotFolders() {
		if other.ID == f.ID {
			continue
		}
		if pathsOverlap(other.LocalPath, f.LocalPath) {
			return fmt.Errorf("%q already syncs an overlapping folder", other.displayName())
		}
		if other.Remote == f.Remote && remotePathsOverlap(other.RemotePath, f.RemotePath) {
			return fmt.Errorf("%q already syncs an overlapping cloud folder", other.displayName())
		}
	}

	if f.Mode == ModeStream {
		return nil
	}
	info, err := os.Stat(f.LocalPath)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("%s does not exist", f.LocalPath)
		}
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("%s is not a folder", f.LocalPath)
	}
	return nil
}

func pathsOverlap(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	a = filepath.Clean(a)
	b = filepath.Clean(b)
	if a == b {
		return true
	}
	return strings.HasPrefix(a, b+string(filepath.Separator)) ||
		strings.HasPrefix(b, a+string(filepath.Separator))
}

func remotePathsOverlap(a, b string) bool {
	a = strings.Trim(a, "/")
	b = strings.Trim(b, "/")
	if a == b {
		return true
	}
	if a == "" || b == "" {
		return true
	}
	return strings.HasPrefix(a, b+"/") || strings.HasPrefix(b, a+"/")
}

// validateFolderID keeps persisted identifiers usable as path components. IDs
// name the bisync work directory and recycle bin, so accepting a separator or
// traversal sequence would let a hand-edited state file escape those roots.
func validateFolderID(id string) error {
	if len(id) == 0 || len(id) > 64 {
		return fmt.Errorf("folder id must be 1 to 64 letters, numbers, dashes or underscores")
	}
	for _, r := range id {
		if !(r >= 'a' && r <= 'z') && !(r >= 'A' && r <= 'Z') && !(r >= '0' && r <= '9') && r != '-' && r != '_' {
			return fmt.Errorf("folder id must be 1 to 64 letters, numbers, dashes or underscores")
		}
	}
	return nil
}

func cleanRemotePath(remotePath string) (string, error) {
	trimmed := strings.Trim(strings.TrimSpace(remotePath), "/")
	if trimmed == "" {
		return "", nil
	}
	for _, part := range strings.Split(trimmed, "/") {
		if part == "." || part == ".." || part == "" {
			return "", fmt.Errorf("cloud path must not contain traversal segments")
		}
	}
	return trimmed, nil
}

func isPathWithin(path, root string) bool {
	path = filepath.Clean(path)
	root = filepath.Clean(root)
	return path != root && strings.HasPrefix(path, root+string(filepath.Separator))
}

func expandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			if p == "~" {
				return home
			}
			return filepath.Join(home, p[2:])
		}
	}
	return p
}

func sanitizeDirName(name string) string {
	replacer := strings.NewReplacer("/", "-", "\\", "-", ":", "-", "\x00", "")
	out := strings.TrimSpace(replacer.Replace(name))
	// Leading dots and dashes would produce a hidden directory or a name that
	// reads like a flag; a traversal attempt collapses to its last segment.
	out = strings.Trim(out, ".-")
	if out == "" {
		return "cloud"
	}
	return out
}
