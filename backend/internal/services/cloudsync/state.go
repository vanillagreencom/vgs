package cloudsync

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// historyLimit bounds the persisted run log. Enough for the Activity view's
// "last few days" feel without growing without bound.
const historyLimit = 200

// configFile is the on-disk shape of ~/.config/vshell/cloudsync.json.
type configFile struct {
	Version  int      `json:"version"`
	Settings Settings `json:"settings"`
	Folders  []Folder `json:"folders"`
	// Accounts holds our own per-account presentation state, keyed by rclone
	// remote name. It lives here rather than in rclone's config so we never
	// write non-rclone keys into a file rclone owns.
	Accounts map[string]AccountMeta `json:"accounts"`
}

// AccountMeta is the part of an account VGS owns. rclone owns the credentials.
type AccountMeta struct {
	Label string `json:"label"`
}

// store owns every path the service persists to and serializes access to them.
type store struct {
	mu sync.Mutex

	configPath  string
	historyPath string
	stateDir    string
	bisyncDir   string
	trashDir    string
	mountRoot   string

	settings Settings
	folders  []Folder
	accounts map[string]AccountMeta
	history  []HistoryEntry

	// rejected names folders dropped by load() because their remote was not a
	// safe, fully validated sync pair. Surfaced once at startup rather than
	// silently activating or deleting them.
	rejected []string
	warnings []string
	// protectConfig backs up a suspect cloudsync.json before the first rewrite,
	// so a corrupt or unsafe config is never silently replaced by defaults.
	protectConfig bool
	// protectHistory applies the same recovery rule to history.json. History is
	// not configuration, but silently replacing a corrupt activity log with one
	// new run makes the original failure impossible to investigate.
	protectHistory bool
}

func newStore() (*store, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolve home directory: %w", err)
	}
	stateDir := filepath.Join(home, ".local", "state", "vshell", "cloudsync")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return nil, fmt.Errorf("create state directory: %w", err)
	}
	configDir := filepath.Join(home, ".config", "vshell")
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		return nil, fmt.Errorf("create config directory: %w", err)
	}
	s := &store{
		configPath:  filepath.Join(configDir, "cloudsync.json"),
		historyPath: filepath.Join(stateDir, "history.json"),
		stateDir:    stateDir,
		bisyncDir:   filepath.Join(stateDir, "bisync"),
		trashDir:    filepath.Join(stateDir, "trash"),
		mountRoot:   filepath.Join(home, "CloudSync"),
		settings:    defaultSettings(),
	}
	if err := os.MkdirAll(s.bisyncDir, 0o700); err != nil {
		return nil, fmt.Errorf("create bisync work directory: %w", err)
	}
	s.load()
	return s, nil
}

// load reads config and history. Missing files are normal first-run state. A
// corrupt or unsafe file is not fatal, but it is recorded and protected from
// silent overwrite until persistConfig has made a backup.
func (s *store) load() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if raw, err := os.ReadFile(s.configPath); err == nil {
		var cfg configFile
		if err := json.Unmarshal(raw, &cfg); err == nil {
			s.settings = s.normalizeLoadedSettings(cfg.Settings)
			s.folders = s.validateLoadedFolders(cfg.Folders)
			s.accounts = cfg.Accounts
		} else {
			s.recordLoadWarningLocked(fmt.Sprintf("Cloud Sync config is corrupt and was not loaded: %s", firstLine(err.Error())))
		}
	} else if !os.IsNotExist(err) {
		s.recordLoadWarningLocked(fmt.Sprintf("Cloud Sync config could not be read: %s", firstLine(err.Error())))
	}
	if raw, err := os.ReadFile(s.historyPath); err == nil {
		var entries []HistoryEntry
		if err := json.Unmarshal(raw, &entries); err == nil {
			s.history = entries
		} else {
			s.recordHistoryWarningLocked(fmt.Sprintf("Cloud Sync history is corrupt and was not loaded: %s", firstLine(err.Error())))
		}
	} else if !os.IsNotExist(err) {
		s.recordHistoryWarningLocked(fmt.Sprintf("Cloud Sync history could not be read: %s", firstLine(err.Error())))
	}
	if s.folders == nil {
		s.folders = []Folder{}
	}
	if s.history == nil {
		s.history = []HistoryEntry{}
	}
	if s.accounts == nil {
		s.accounts = map[string]AccountMeta{}
	}
}

func (s *store) recordLoadWarningLocked(message string) {
	s.warnings = append(s.warnings, message)
	s.protectConfig = true
}

func (s *store) recordHistoryWarningLocked(message string) {
	s.warnings = append(s.warnings, message)
	s.protectHistory = true
}

func (s *store) normalizeLoadedSettings(in Settings) Settings {
	out := mergeSettings(in)
	if err := validateSettings(&out); err != nil {
		s.recordLoadWarningLocked(fmt.Sprintf("Ignored unsafe Cloud Sync settings from config: %s", firstLine(err.Error())))
		return defaultSettings()
	}
	root := strings.TrimSpace(out.MountRoot)
	if root == "" {
		return out
	}
	resolved := filepath.Clean(expandHome(root))
	if !filepath.IsAbs(resolved) {
		s.recordLoadWarningLocked("Ignored unsafe Cloud Sync mount root from config: it was not absolute")
		out.MountRoot = ""
		return out
	}
	home, err := os.UserHomeDir()
	if err != nil {
		s.recordLoadWarningLocked("Ignored Cloud Sync mount root because the home directory could not be resolved")
		out.MountRoot = ""
		return out
	}
	if resolved != home && !strings.HasPrefix(resolved, home+string(os.PathSeparator)) {
		s.recordLoadWarningLocked("Ignored unsafe Cloud Sync mount root from config: it was outside the home directory")
		out.MountRoot = ""
		return out
	}
	out.MountRoot = resolved
	return out
}

func (s *store) validateLoadedFolders(folders []Folder) []Folder {
	kept := make([]Folder, 0, len(folders))
	for _, raw := range folders {
		folder, err := s.normalizeLoadedFolder(raw, kept)
		if err != nil {
			label := firstNonEmpty(raw.Name, raw.ID, raw.Remote, raw.LocalPath, "unnamed folder")
			s.rejected = append(s.rejected, label)
			s.recordLoadWarningLocked(fmt.Sprintf("Ignored unsafe Cloud Sync folder %q from config: %s", label, firstLine(err.Error())))
			continue
		}
		kept = append(kept, folder)
	}
	return kept
}

func (s *store) normalizeLoadedFolder(f Folder, existing []Folder) (Folder, error) {
	f.ID = strings.TrimSpace(f.ID)
	if err := validateFolderID(f.ID); err != nil {
		return f, err
	}
	f.Remote = strings.TrimSuffix(strings.TrimSpace(f.Remote), ":")
	if err := validateRemoteName(f.Remote); err != nil {
		return f, err
	}
	if !f.Mode.Valid() {
		return f, fmt.Errorf("mode is invalid")
	}
	if f.IntervalSeconds < 0 || f.IntervalSeconds > maxPersistedIntervalSeconds {
		return f, fmt.Errorf("sync interval is out of range")
	}
	if f.MaxDelete < -1 {
		return f, fmt.Errorf("maximum deletions must be -1 or a non-negative number")
	}
	remotePath, err := cleanRemotePath(f.RemotePath)
	if err != nil {
		return f, err
	}
	f.RemotePath = remotePath
	f.Name = strings.TrimSpace(f.Name)
	if f.MaxDelete == 0 {
		f.MaxDelete = -1
	}
	if f.Excludes == nil {
		f.Excludes = []string{}
	}
	if f.CreatedUnix == 0 {
		f.CreatedUnix = nowUnix()
	}
	local, err := s.resolveLoadedLocalPath(f)
	if err != nil {
		return f, err
	}
	f.LocalPath = local
	if f.Name == "" {
		f.Name = filepath.Base(local)
	}
	if f.Mode == ModeStream {
		if f.IntervalSeconds != 0 || f.RealTime {
			return f, fmt.Errorf("streamed folders cannot be scheduled or watched")
		}
	}
	if f.Mode != ModeTwoWay {
		f.ResyncDone = true
	}
	if err := validateLoadedFolderPair(f, existing); err != nil {
		return f, err
	}
	return f, nil
}

func (s *store) resolveLoadedLocalPath(f Folder) (string, error) {
	if f.Mode == ModeStream {
		root := strings.TrimSpace(s.settings.MountRoot)
		if root == "" {
			root = s.mountRoot
		}
		name := f.Name
		if name == "" {
			name = f.Remote
			if f.RemotePath != "" {
				name = f.Remote + "-" + strings.ReplaceAll(f.RemotePath, "/", "-")
			}
		}
		mountPoint := filepath.Clean(filepath.Join(expandHome(root), sanitizeDirName(name)))
		if !isPathWithin(mountPoint, filepath.Clean(expandHome(root))) {
			return "", fmt.Errorf("stream mount path escaped the Cloud Sync mount root")
		}
		return mountPoint, nil
	}
	local := expandHome(strings.TrimSpace(f.LocalPath))
	if local == "" {
		return "", fmt.Errorf("local folder is empty")
	}
	if !filepath.IsAbs(local) {
		return "", fmt.Errorf("local folder must be absolute")
	}
	return filepath.Clean(local), nil
}

func validateLoadedFolderPair(f Folder, existing []Folder) error {
	home, err := os.UserHomeDir()
	if err == nil && f.LocalPath == filepath.Clean(home) {
		return fmt.Errorf("syncing the entire home directory is not supported")
	}
	if f.LocalPath == "/" || f.LocalPath == "" {
		return fmt.Errorf("local folder cannot be the filesystem root")
	}
	for _, other := range existing {
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
		return fmt.Errorf("local folder cannot be inspected: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("local path is not a folder")
	}
	return nil
}

// mergeSettings fills zero values from an older or partial config with the
// current defaults, so adding a setting never breaks an existing install.
func mergeSettings(in Settings) Settings {
	out := in
	def := defaultSettings()
	if out.Transfers <= 0 {
		out.Transfers = def.Transfers
	}
	if out.Checkers <= 0 {
		out.Checkers = def.Checkers
	}
	if out.TrashRetentionDays <= 0 {
		out.TrashRetentionDays = def.TrashRetentionDays
	}
	return out
}

func (s *store) snapshotFolders() []Folder {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Folder, len(s.folders))
	copy(out, s.folders)
	return out
}

func (s *store) folder(id string) (Folder, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, f := range s.folders {
		if f.ID == id {
			return f, true
		}
	}
	return Folder{}, false
}

func (s *store) snapshotSettings() Settings {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.settings
}

func (s *store) snapshotWarnings() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, len(s.warnings))
	copy(out, s.warnings)
	return out
}

func (s *store) putFolder(f Folder) error {
	s.mu.Lock()
	replaced := false
	for i := range s.folders {
		if s.folders[i].ID == f.ID {
			s.folders[i] = f
			replaced = true
			break
		}
	}
	if !replaced {
		s.folders = append(s.folders, f)
	}
	s.mu.Unlock()
	return s.persistConfig()
}

func (s *store) deleteFolder(id string) (Folder, error) {
	s.mu.Lock()
	var removed Folder
	found := false
	kept := s.folders[:0]
	for _, f := range s.folders {
		if f.ID == id {
			removed, found = f, true
			continue
		}
		kept = append(kept, f)
	}
	s.folders = append([]Folder{}, kept...)
	s.mu.Unlock()
	if !found {
		return Folder{}, fmt.Errorf("no such folder")
	}
	return removed, s.persistConfig()
}

// accountMeta returns the presentation state for one remote. A remote with no
// entry is normal: it simply has no user-chosen label.
func (s *store) accountMeta(name string) AccountMeta {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.accounts[name]
}

func (s *store) putAccountMeta(name string, meta AccountMeta) error {
	s.mu.Lock()
	if s.accounts == nil {
		s.accounts = map[string]AccountMeta{}
	}
	if meta == (AccountMeta{}) {
		delete(s.accounts, name)
	} else {
		s.accounts[name] = meta
	}
	s.mu.Unlock()
	return s.persistConfig()
}

// pruneAccountMeta drops presentation state for remotes that no longer exist.
// Only called with a list built from a successful config/listremotes, so a
// failed listing can never wipe every label.
func (s *store) pruneAccountMeta(live map[string]bool) error {
	s.mu.Lock()
	removed := false
	for name := range s.accounts {
		if !live[name] {
			delete(s.accounts, name)
			removed = true
		}
	}
	s.mu.Unlock()
	if !removed {
		return nil
	}
	return s.persistConfig()
}

func (s *store) deleteAccountMeta(name string) error {
	s.mu.Lock()
	_, exists := s.accounts[name]
	delete(s.accounts, name)
	s.mu.Unlock()
	if !exists {
		return nil
	}
	return s.persistConfig()
}

// foldersForRemote lists every sync pair pointing at one account. Used to warn
// before a disconnect, which would otherwise leave those pairs unrunnable.
func (s *store) foldersForRemote(remote string) []Folder {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Folder, 0, 4)
	for _, f := range s.folders {
		if f.Remote == remote {
			out = append(out, f)
		}
	}
	return out
}

func (s *store) putSettings(in Settings) error {
	s.mu.Lock()
	s.settings = mergeSettings(in)
	s.mu.Unlock()
	return s.persistConfig()
}

func (s *store) persistConfig() error {
	s.mu.Lock()
	cfg := configFile{Version: 1, Settings: s.settings, Folders: s.folders, Accounts: s.accounts}
	path := s.configPath
	s.mu.Unlock()
	if err := s.backupConfigIfProtected(path); err != nil {
		return err
	}
	return writeJSONAtomic(path, cfg)
}

func (s *store) backupConfigIfProtected(path string) error {
	s.mu.Lock()
	if !s.protectConfig {
		s.mu.Unlock()
		return nil
	}
	s.mu.Unlock()

	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		s.mu.Lock()
		s.protectConfig = false
		s.mu.Unlock()
		return nil
	}
	if err != nil {
		return fmt.Errorf("protect Cloud Sync config before rewriting it: %w", err)
	}
	backup := fmt.Sprintf("%s.invalid.%d", path, time.Now().Unix())
	if err := os.WriteFile(backup, raw, 0o600); err != nil {
		return fmt.Errorf("back up unsafe Cloud Sync config before rewriting it: %w", err)
	}
	s.mu.Lock()
	s.protectConfig = false
	s.warnings = append(s.warnings, "Backed up the previous Cloud Sync config before writing repaired state: "+backup)
	s.mu.Unlock()
	return nil
}

func (s *store) appendHistory(entry HistoryEntry) []HistoryEntry {
	s.mu.Lock()
	s.history = append([]HistoryEntry{entry}, s.history...)
	if len(s.history) > historyLimit {
		s.history = s.history[:historyLimit]
	}
	out := make([]HistoryEntry, len(s.history))
	copy(out, s.history)
	path := s.historyPath
	protected := s.protectHistory
	s.mu.Unlock()

	if protected {
		if err := s.backupHistoryIfProtected(path); err != nil {
			return out
		}
	}
	// History is a convenience log; a write failure must not break syncing.
	_ = writeJSONAtomic(path, out)
	return out
}

func (s *store) backupHistoryIfProtected(path string) error {
	s.mu.Lock()
	if !s.protectHistory {
		s.mu.Unlock()
		return nil
	}
	s.mu.Unlock()

	raw, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		s.mu.Lock()
		s.protectHistory = false
		s.mu.Unlock()
		return nil
	}
	if err != nil {
		return fmt.Errorf("protect Cloud Sync history before rewriting it: %w", err)
	}
	backup := fmt.Sprintf("%s.invalid.%d", path, time.Now().Unix())
	if err := os.WriteFile(backup, raw, 0o600); err != nil {
		return fmt.Errorf("back up unsafe Cloud Sync history before rewriting it: %w", err)
	}
	s.mu.Lock()
	s.protectHistory = false
	s.warnings = append(s.warnings, "Backed up the previous Cloud Sync history before writing new activity: "+backup)
	s.mu.Unlock()
	return nil
}

func (s *store) snapshotHistory() []HistoryEntry {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]HistoryEntry, len(s.history))
	copy(out, s.history)
	return out
}

// localTrash is the recycle bin for a folder's local side. Overwrites and
// deletes land here instead of vanishing, which is what makes two-way sync
// recoverable.
func (s *store) localTrash(folderID string) string {
	return filepath.Join(s.trashDir, folderID)
}

func (s *store) bisyncWorkdir(folderID string) string {
	return filepath.Join(s.bisyncDir, folderID)
}

// pruneTrash deletes local trash entries older than the retention window.
func (s *store) pruneTrash(olderThanUnix int64) {
	entries, err := os.ReadDir(s.trashDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		path := filepath.Join(s.trashDir, entry.Name())
		pruneTrashTree(path, olderThanUnix)
	}
}

func pruneTrashTree(root string, olderThanUnix int64) {
	var dirs []string
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.IsDir() {
			if path != root {
				dirs = append(dirs, path)
			}
			return nil
		}
		if info.ModTime().Unix() < olderThanUnix {
			_ = os.Remove(path)
		}
		return nil
	})
	// Deepest first, so emptied directories collapse in one pass.
	sort.Slice(dirs, func(i, j int) bool { return len(dirs[i]) > len(dirs[j]) })
	for _, dir := range dirs {
		_ = os.Remove(dir) // fails harmlessly when the directory still has files
	}
}

// writeJSONAtomic writes via a temp file + rename so a crash mid-write can
// never leave a truncated config behind.
func writeJSONAtomic(path string, value any) error {
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)

	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}
