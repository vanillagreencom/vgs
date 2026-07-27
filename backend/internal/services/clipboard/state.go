package clipboard

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

// maxUnpinned bounds the history to pinned entries plus the newest unpinned
// ones, matching the helper's persistence contract.
const maxUnpinned = 100

// maxPinned mirrors the client-side pin cap so the limit holds even for
// callers that skip the getPinnedCount pre-check.
const maxPinned = 25

// Entry is one clipboard history item. Text entries persist their full text;
// image entries persist only the file path (the blob lives in the images dir).
// The legacy helper format carried an inline base64 "data" field — it is
// intentionally absent here so loading and re-saving migrates old state files.
type Entry struct {
	ID        int64  `json:"id"`
	Hash      string `json:"hash"`
	Preview   string `json:"preview"`
	Text      string `json:"text,omitempty"`
	Size      int64  `json:"size"`
	IsImage   bool   `json:"isImage"`
	Mime      string `json:"mime"`
	Pinned    bool   `json:"pinned"`
	Timestamp int64  `json:"timestamp"`
	Path      string `json:"path,omitempty"`
}

type state struct {
	NextID  int64    `json:"nextId"`
	Entries []*Entry `json:"entries"`
}

// publicEntry is the wire shape served to QML: full text is truncated, and
// mime is duplicated as mimeType for existing consumers.
func publicEntry(e *Entry) map[string]any {
	text := truncateRunes(e.Text, 500)
	mime := e.Mime
	if mime == "" {
		if e.IsImage {
			mime = "image/png"
		} else {
			mime = "text/plain"
		}
	}
	return map[string]any{
		"id":        e.ID,
		"hash":      e.Hash,
		"preview":   e.Preview,
		"text":      text,
		"size":      e.Size,
		"isImage":   e.IsImage,
		"mime":      mime,
		"mimeType":  mime,
		"pinned":    e.Pinned,
		"timestamp": e.Timestamp,
		"path":      e.Path,
	}
}

// sortEntries orders pinned first, then newest by timestamp, id as tiebreak.
func sortEntries(entries []*Entry) {
	sort.SliceStable(entries, func(i, j int) bool {
		a, b := entries[i], entries[j]
		if a.Pinned != b.Pinned {
			return a.Pinned
		}
		if a.Timestamp != b.Timestamp {
			return a.Timestamp > b.Timestamp
		}
		return a.ID > b.ID
	})
}

// stateDir returns the VGS state directory, matching the helper's state_dir.
func stateDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "state", "vshell"), nil
}

// store owns the on-disk representation. All access goes through the Manager's
// mutex; the file lock exists to serialize with the Python helper CLI, which
// may still mutate the same file when invoked manually.
type store struct {
	log       *slog.Logger
	stateFile string
	lockFile  string
	watchLock string
	imagesDir string

	// lastMod/lastSize detect out-of-band writes (helper CLI) so the manager
	// re-reads instead of clobbering them with stale in-memory state.
	lastMod  time.Time
	lastSize int64
}

func newStore(log *slog.Logger) (*store, error) {
	dir, err := stateDir()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	return &store{
		log:       log,
		stateFile: filepath.Join(dir, "clipboard-history.json"),
		lockFile:  filepath.Join(dir, "clipboard-history.lock"),
		watchLock: filepath.Join(dir, "clipboard-watch.lock"),
		imagesDir: filepath.Join(dir, "clipboard-images"),
	}, nil
}

// tryWatchLock claims the system-wide clipboard-watcher lock — the same file
// the helper's `vshell clipboard watch` guards itself with — so exactly one
// watcher can exist across the backend and any manual fallback. Returns a
// release func on success, ok=false when another watcher holds it.
func (st *store) tryWatchLock() (release func(), ok bool, err error) {
	f, err := os.OpenFile(st.watchLock, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, false, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if err == syscall.EWOULDBLOCK {
			return nil, false, nil
		}
		return nil, false, err
	}
	return func() {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, true, nil
}

// lockAcquireTimeout bounds how long any operation waits for the
// cross-process history lock. The helper CLI holds it for milliseconds; a
// holder stuck longer than this must surface as an error instead of wedging
// handlers (and, transitively, Manager.Close).
const lockAcquireTimeout = 5 * time.Second

// withLock runs fn while holding the cross-process history lock.
func (st *store) withLock(fn func() error) error {
	f, err := os.OpenFile(st.lockFile, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	deadline := time.Now().Add(lockAcquireTimeout)
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EINTR {
			return err
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("clipboard state lock busy")
		}
		time.Sleep(10 * time.Millisecond)
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return fn()
}

// load reads the state file. A missing file is an empty state; an unreadable
// one is moved aside (like the helper) so history can restart cleanly.
func (st *store) load() (*state, string, error) {
	data, err := os.ReadFile(st.stateFile)
	if os.IsNotExist(err) {
		st.lastMod, st.lastSize = time.Time{}, 0
		return &state{NextID: 1}, "", nil
	}
	if err != nil {
		return nil, "", err
	}
	st.noteFileInfo()
	var s state
	if err := json.Unmarshal(data, &s); err != nil {
		corrupt := fmt.Sprintf("%s.corrupt-%d", st.stateFile, time.Now().Unix())
		warn := fmt.Sprintf("clipboard history was corrupt; moved to %s: %v", corrupt, err)
		if mvErr := os.Rename(st.stateFile, corrupt); mvErr != nil {
			warn = fmt.Sprintf("clipboard history was corrupt and could not be moved: %v", err)
		}
		return &state{NextID: 1}, warn, nil
	}
	if s.NextID < 1 {
		s.NextID = 1
	}
	return &s, "", nil
}

// save trims, persists atomically, and prunes unreferenced image files.
func (st *store) save(s *state) error {
	pinned := make([]*Entry, 0, len(s.Entries))
	unpinned := make([]*Entry, 0, len(s.Entries))
	for _, e := range s.Entries {
		if e.Pinned {
			pinned = append(pinned, e)
		} else {
			unpinned = append(unpinned, e)
		}
	}
	sortEntries(unpinned)
	if len(unpinned) > maxUnpinned {
		unpinned = unpinned[:maxUnpinned]
	}
	s.Entries = append(pinned, unpinned...)
	sortEntries(s.Entries)

	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := fmt.Sprintf("%s.tmp.%d", st.stateFile, os.Getpid())
	if err := os.WriteFile(tmp, append(data, '\n'), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, st.stateFile); err != nil {
		os.Remove(tmp)
		return err
	}
	st.noteFileInfo()
	st.pruneImages(s)
	return nil
}

func (st *store) noteFileInfo() {
	if fi, err := os.Stat(st.stateFile); err == nil {
		st.lastMod, st.lastSize = fi.ModTime(), fi.Size()
	}
}

// changedOnDisk reports whether the state file was modified by another
// process since this store last read or wrote it.
func (st *store) changedOnDisk() bool {
	fi, err := os.Stat(st.stateFile)
	if err != nil {
		return !st.lastMod.IsZero()
	}
	return !fi.ModTime().Equal(st.lastMod) || fi.Size() != st.lastSize
}

// writeImage stores an image blob under its content hash, returning the path.
func (st *store) writeImage(hash, mime string, blob []byte) (string, error) {
	if err := os.MkdirAll(st.imagesDir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(st.imagesDir, hash+"."+imageExt(mime))
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if err := os.WriteFile(tmp, blob, 0o644); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return "", err
	}
	return path, nil
}

// pruneImages removes image files no entry references anymore. Only files
// that look like content-hash names are touched.
func (st *store) pruneImages(s *state) {
	items, err := os.ReadDir(st.imagesDir)
	if err != nil {
		if !os.IsNotExist(err) {
			st.log.Warn("clipboard image prune: cannot read images dir", "err", err)
		}
		return
	}
	referenced := map[string]bool{}
	for _, e := range s.Entries {
		if e.Path != "" {
			referenced[filepath.Base(e.Path)] = true
		}
	}
	for _, item := range items {
		name := item.Name()
		if item.IsDir() || referenced[name] {
			continue
		}
		base, _, ok := strings.Cut(name, ".")
		if !ok || len(base) != 64 || !isHex(base) {
			continue
		}
		if err := os.Remove(filepath.Join(st.imagesDir, name)); err != nil {
			st.log.Warn("clipboard image prune failed", "file", name, "err", err)
		}
	}
}

func isHex(s string) bool {
	_, err := hex.DecodeString(s)
	return err == nil
}

func imageExt(mime string) string {
	if mime == "image/png" {
		return "png"
	}
	ext := mime
	if _, after, ok := strings.Cut(mime, "/"); ok {
		ext = after
	}
	return strings.ReplaceAll(ext, "+xml", "")
}

// truncateRunes shortens s to at most n runes without splitting a code point.
func truncateRunes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	runes := 0
	for i := range s {
		if runes == n {
			return s[:i]
		}
		runes++
	}
	return s
}

func hashText(text string) string {
	sum := sha256.Sum256(append([]byte("text\x00"), text...))
	return hex.EncodeToString(sum[:])
}

func hashImage(blob []byte) string {
	sum := sha256.Sum256(append([]byte("image\x00"), blob...))
	return hex.EncodeToString(sum[:])
}
