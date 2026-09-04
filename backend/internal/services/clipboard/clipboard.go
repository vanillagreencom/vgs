// Package clipboard owns the clipboard watcher, history file, and image store.
// The helper CLI shares the history file and locks for manual use.
package clipboard

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"vshell/backend/internal/server"
)

const (
	// debounceDelay coalesces the burst of watch events a single copy can
	// produce (each offered mime type may fire once) into one poll.
	debounceDelay = 250 * time.Millisecond
	// watchRestartMin/Max bound restart backoff. The loop retries until shutdown
	// because watcher failure stops history recording.
	watchRestartMin = time.Second
	watchRestartMax = 30 * time.Second
	// maxEntryData bounds the base64 payload getEntry returns inline. Larger
	// images are still served by path.
	maxEntryData = 2 << 20
	previewLen   = 240
)

// errNoChange lets a mutate callback report "nothing to do" so the save and
// broadcast are skipped while the operation still succeeds.
var errNoChange = errors.New("no change")

type Manager struct {
	log *slog.Logger
	srv *server.Server

	mu    sync.Mutex
	state *state
	store *store

	// Subscription snapshots run on the send-queue goroutine. They must read the
	// cache without m.mu: a handler can hold that mutex while waiting for queue
	// space, causing deadlock if the snapshot also waits for it.
	snapshot atomic.Value

	events chan struct{}
	stop   context.CancelFunc
	wg     sync.WaitGroup
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	if log == nil {
		log = slog.Default()
	}
	for _, tool := range []string{"wl-paste", "wl-copy"} {
		if _, err := exec.LookPath(tool); err != nil {
			return nil, fmt.Errorf("%s not found", tool)
		}
	}
	st, err := newStore(log)
	if err != nil {
		return nil, err
	}
	m := &Manager{
		log:    log,
		srv:    srv,
		store:  st,
		events: make(chan struct{}, 1),
	}
	if err := m.store.withLock(m.loadLocked); err != nil {
		return nil, err
	}
	m.snapshot.Store(m.historyPayloadLocked())

	srv.Register("clipboard", "clipboard.getHistory", m.handleGetHistory)
	srv.Register("clipboard", "clipboard.search", m.handleSearch)
	srv.Register("clipboard", "clipboard.getEntry", m.handleGetEntry)
	srv.Register("clipboard", "clipboard.copyEntry", m.handleCopyEntry)
	srv.Register("clipboard", "clipboard.copy", m.handleCopy)
	srv.Register("clipboard", "clipboard.deleteEntry", m.handleDeleteEntry)
	srv.Register("clipboard", "clipboard.getPinnedCount", m.handleGetPinnedCount)
	srv.Register("clipboard", "clipboard.pinEntry", m.handlePinEntry)
	srv.Register("clipboard", "clipboard.unpinEntry", m.handleUnpinEntry)
	srv.Register("clipboard", "clipboard.clearHistory", m.handleClearHistory)
	srv.Register("clipboard", "clipboard.getConfig", m.handleGetConfig)
	srv.Register("clipboard", "clipboard.setConfig", m.handleSetConfig)
	srv.RegisterSnapshot("clipboard", func() any { return m.snapshot.Load() })

	ctx, cancel := context.WithCancel(context.Background())
	m.stop = cancel
	m.wg.Add(2)
	go m.watchLoop(ctx)
	go m.pollLoop(ctx)
	m.signalEvent() // pick up whatever is on the clipboard at startup

	return m, nil
}

func (m *Manager) Close() {
	m.stop()
	m.wg.Wait()
}

// watchLoop restarts wl-paste with capped backoff and cancels it on shutdown.
// The shared watch lock excludes the manual clipboard watcher while this loop
// owns it.
func (m *Manager) watchLoop(ctx context.Context) {
	defer m.wg.Done()
	delay := watchRestartMin
	warnedBusy := false
	for ctx.Err() == nil {
		release, ok, err := m.store.tryWatchLock()
		if err != nil || !ok {
			if !warnedBusy {
				m.log.Warn("clipboard watch lock unavailable; standing by", "err", err)
				warnedBusy = true
			}
		} else {
			warnedBusy = false
			started := time.Now()
			err := watch(ctx, m.signalEvent)
			release()
			if ctx.Err() != nil {
				return
			}
			if time.Since(started) > time.Minute {
				delay = watchRestartMin
			}
			m.log.Warn("clipboard watcher exited; restarting", "err", err, "delay", delay)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}
		if delay *= 2; delay > watchRestartMax {
			delay = watchRestartMax
		}
	}
}

func (m *Manager) signalEvent() {
	select {
	case m.events <- struct{}{}:
	default:
	}
}

func (m *Manager) pollLoop(ctx context.Context) {
	defer m.wg.Done()
	for {
		select {
		case <-ctx.Done():
			return
		case <-m.events:
		}
		timer := time.NewTimer(debounceDelay)
	drain:
		for {
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-m.events:
				// Another change landed inside the window; restart it so the
				// poll reads the final content once.
				if !timer.Stop() {
					<-timer.C
				}
				timer.Reset(debounceDelay)
			case <-timer.C:
				break drain
			}
		}
		if err := m.pollOnce(); err != nil {
			m.log.Warn("clipboard poll failed", "err", err)
		}
	}
}

func (m *Manager) pollOnce() error {
	sel, ok, err := readSelection(m.log)
	if err != nil || !ok {
		return err
	}
	if sel.text != "" {
		return m.mutate(func() error { return m.upsertTextLocked(sel.text) })
	}
	return m.mutate(func() error {
		hash := hashImage(sel.image)
		if e := m.findByHashLocked(hash); e != nil {
			e.Timestamp = nowMs()
			// Self-heal: the blob may have been deleted out-of-band while the
			// entry survived; the fresh bytes are in hand, so rewrite instead
			// of bumping an entry whose thumbnail and copyEntry would fail.
			if _, err := os.Stat(e.Path); e.Path == "" || err != nil {
				if path, err := m.store.writeImage(hash, sel.mime, sel.image); err == nil {
					e.Path = path
				} else {
					m.log.Warn("clipboard image self-heal failed", "err", err)
				}
			}
			return nil
		}
		path, err := m.store.writeImage(hash, sel.mime, sel.image)
		if err != nil {
			return err
		}
		m.state.Entries = append(m.state.Entries, &Entry{
			ID:        m.takeIDLocked(),
			Hash:      hash,
			Preview:   fmt.Sprintf("Image (%s)", sel.mime),
			Size:      int64(len(sel.image)),
			IsImage:   true,
			Mime:      sel.mime,
			Timestamp: nowMs(),
			Path:      path,
		})
		return nil
	})
}

// upsertTextLocked records text content, bumping an existing entry with the
// same hash to the top instead of duplicating it. Runs inside mutate.
func (m *Manager) upsertTextLocked(text string) error {
	hash := hashText(text)
	if e := m.findByHashLocked(hash); e != nil {
		e.Timestamp = nowMs()
		return nil
	}
	m.state.Entries = append(m.state.Entries, &Entry{
		ID:        m.takeIDLocked(),
		Hash:      hash,
		Preview:   truncateRunes(strings.ReplaceAll(text, "\n", " "), previewLen),
		Text:      text,
		Size:      int64(len(text)),
		Mime:      "text/plain",
		Timestamp: nowMs(),
	})
	return nil
}

// loadLocked replaces in-memory state from disk. The caller must hold the
// cross-process flock (and m.mu once the manager is published).
func (m *Manager) loadLocked() error {
	loaded, warn, err := m.store.load()
	if err != nil {
		return err
	}
	if warn != "" {
		m.log.Warn(warn)
	}
	m.state = loaded
	return nil
}

// refreshLocked re-reads state another process wrote since our last disk
// touch. The caller must hold both m.mu and the flock.
func (m *Manager) refreshLocked() {
	if !m.store.changedOnDisk() {
		return
	}
	if err := m.loadLocked(); err != nil {
		m.log.Warn("clipboard state re-read failed", "err", err)
	}
}

// syncLocked is refreshLocked for read-only paths that do not already hold
// the flock. The caller must hold m.mu.
func (m *Manager) syncLocked() {
	if !m.store.changedOnDisk() {
		return
	}
	if err := m.store.withLock(m.loadLocked); err != nil {
		m.log.Warn("clipboard state re-read failed", "err", err)
		return
	}
	m.snapshot.Store(m.historyPayloadLocked())
}

// mutate holds the shared file lock through read, change, and save to exclude
// helper CLI writes. Broadcast follows release of m.mu because a full server
// queue can block.
func (m *Manager) mutate(fn func() error) error {
	m.mu.Lock()
	changed := true
	err := m.store.withLock(func() error {
		m.refreshLocked()
		if err := fn(); err != nil {
			if errors.Is(err, errNoChange) {
				changed = false
				return nil
			}
			return err
		}
		return m.store.save(m.state)
	})
	var payload any
	if err == nil && changed {
		payload = m.historyPayloadLocked()
		m.snapshot.Store(payload)
	}
	m.mu.Unlock()
	if err == nil && changed {
		m.srv.Broadcast("clipboard", payload)
	}
	return err
}

func (m *Manager) historyPayloadLocked() any {
	sortEntries(m.state.Entries)
	history := make([]map[string]any, 0, len(m.state.Entries))
	for _, e := range m.state.Entries {
		history = append(history, publicEntry(e))
	}
	return map[string]any{"available": true, "history": history}
}

func (m *Manager) findByHashLocked(hash string) *Entry {
	for _, e := range m.state.Entries {
		if e.Hash == hash {
			return e
		}
	}
	return nil
}

func (m *Manager) findByIDLocked(id int64) *Entry {
	for _, e := range m.state.Entries {
		if e.ID == id {
			return e
		}
	}
	return nil
}

func (m *Manager) takeIDLocked() int64 {
	id := m.state.NextID
	m.state.NextID++
	return id
}

type idParams struct {
	ID int64 `json:"id"`
}

func parseID(params json.RawMessage) (int64, error) {
	var p idParams
	if err := json.Unmarshal(params, &p); err != nil {
		return 0, fmt.Errorf("invalid clipboard params: %w", err)
	}
	return p.ID, nil
}

func (m *Manager) handleGetHistory(json.RawMessage) (any, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.syncLocked()
	sortEntries(m.state.Entries)
	history := make([]map[string]any, 0, len(m.state.Entries))
	for _, e := range m.state.Entries {
		history = append(history, publicEntry(e))
	}
	return history, nil
}

func (m *Manager) handleSearch(params json.RawMessage) (any, error) {
	var p struct {
		Query string `json:"query"`
		Limit int    `json:"limit"`
	}
	if len(params) > 0 {
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, fmt.Errorf("invalid clipboard params: %w", err)
		}
	}
	if p.Limit <= 0 {
		p.Limit = 20
	}
	query := strings.ToLower(p.Query)

	m.mu.Lock()
	defer m.mu.Unlock()
	m.syncLocked()
	sortEntries(m.state.Entries)
	matches := make([]map[string]any, 0, p.Limit)
	for _, e := range m.state.Entries {
		haystack := e.Preview
		if haystack == "" {
			haystack = e.Text
		}
		if !strings.Contains(strings.ToLower(haystack), query) {
			continue
		}
		matches = append(matches, publicEntry(e))
		if len(matches) >= p.Limit {
			break
		}
	}
	return map[string]any{"entries": matches}, nil
}

func (m *Manager) handleGetEntry(params json.RawMessage) (any, error) {
	id, err := parseID(params)
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.syncLocked()
	e := m.findByIDLocked(id)
	if e == nil {
		return nil, nil
	}
	out := publicEntry(e)
	out["data"] = m.entryData(e)
	return out, nil
}

// entryData returns full text or image bytes within the inline cap. Missing and
// oversized images both return an empty string; read errors are logged to
// distinguish them.
func (m *Manager) entryData(e *Entry) string {
	if !e.IsImage {
		return base64.StdEncoding.EncodeToString([]byte(e.Text))
	}
	if e.Path == "" || e.Size > maxEntryData {
		return ""
	}
	blob, err := os.ReadFile(e.Path)
	if err != nil {
		m.log.Warn("clipboard image blob unreadable", "path", e.Path, "err", err)
		return ""
	}
	if len(blob) > maxEntryData {
		return ""
	}
	return base64.StdEncoding.EncodeToString(blob)
}

func (m *Manager) handleCopyEntry(params json.RawMessage) (any, error) {
	id, err := parseID(params)
	if err != nil {
		return nil, err
	}
	// Run wl-copy and image reads outside the lock so other clipboard methods can
	// proceed during I/O.
	m.mu.Lock()
	m.syncLocked()
	e := m.findByIDLocked(id)
	if e == nil {
		m.mu.Unlock()
		return nil, fmt.Errorf("entry not found")
	}
	isImage, path, text, mime := e.IsImage, e.Path, e.Text, e.Mime
	m.mu.Unlock()

	if isImage {
		blob, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("image file missing")
		}
		if err := wlCopy(m.log, blob, mime); err != nil {
			return nil, err
		}
	} else if err := wlCopy(m.log, []byte(text), ""); err != nil {
		return nil, err
	}
	// Bump immediately so the UI reorders without waiting for the watch
	// event; the event's poll then dedups by hash into this same entry.
	err = m.mutate(func() error {
		e := m.findByIDLocked(id)
		if e == nil {
			return errNoChange
		}
		e.Timestamp = nowMs()
		return nil
	})
	if err != nil {
		return nil, err
	}
	return true, nil
}

func (m *Manager) handleCopy(params json.RawMessage) (any, error) {
	var p struct {
		Text string `json:"text"`
	}
	if len(params) > 0 {
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, fmt.Errorf("invalid clipboard params: %w", err)
		}
	}
	if err := wlCopy(m.log, []byte(p.Text), ""); err != nil {
		return nil, err
	}
	if p.Text == "" {
		return true, nil
	}
	if err := m.mutate(func() error { return m.upsertTextLocked(p.Text) }); err != nil {
		return nil, err
	}
	return true, nil
}

func (m *Manager) handleDeleteEntry(params json.RawMessage) (any, error) {
	id, err := parseID(params)
	if err != nil {
		return nil, err
	}
	err = m.mutate(func() error {
		kept := m.state.Entries[:0]
		removed := false
		for _, e := range m.state.Entries {
			if e.ID == id {
				removed = true
				continue
			}
			kept = append(kept, e)
		}
		if !removed {
			return errNoChange
		}
		m.state.Entries = kept
		return nil
	})
	if err != nil {
		return nil, err
	}
	return true, nil
}

func (m *Manager) handleGetPinnedCount(json.RawMessage) (any, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.syncLocked()
	count := 0
	for _, e := range m.state.Entries {
		if e.Pinned {
			count++
		}
	}
	return map[string]any{"count": count}, nil
}

func (m *Manager) handlePinEntry(params json.RawMessage) (any, error) {
	return m.setPinned(params, true)
}

func (m *Manager) handleUnpinEntry(params json.RawMessage) (any, error) {
	return m.setPinned(params, false)
}

func (m *Manager) setPinned(params json.RawMessage, pinned bool) (any, error) {
	id, err := parseID(params)
	if err != nil {
		return nil, err
	}
	err = m.mutate(func() error {
		e := m.findByIDLocked(id)
		if e == nil {
			return fmt.Errorf("entry not found")
		}
		if e.Pinned == pinned {
			return errNoChange
		}
		if pinned {
			count := 0
			for _, other := range m.state.Entries {
				if other.Pinned {
					count++
				}
			}
			if count >= maxPinned {
				return fmt.Errorf("maximum pinned entries reached (%d)", maxPinned)
			}
		}
		e.Pinned = pinned
		return nil
	})
	if err != nil {
		return nil, err
	}
	return true, nil
}

func (m *Manager) handleClearHistory(json.RawMessage) (any, error) {
	err := m.mutate(func() error {
		kept := m.state.Entries[:0]
		for _, e := range m.state.Entries {
			if e.Pinned {
				kept = append(kept, e)
			}
		}
		m.state.Entries = kept
		return nil
	})
	if err != nil {
		return nil, err
	}
	return true, nil
}

func (m *Manager) handleGetConfig(json.RawMessage) (any, error) {
	return map[string]any{}, nil
}

func (m *Manager) handleSetConfig(json.RawMessage) (any, error) {
	return true, nil
}

func nowMs() int64 {
	return time.Now().UnixMilli()
}
