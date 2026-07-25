package clipboard

import (
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"vshell/backend/internal/server"
)

func testStore(t *testing.T) *store {
	t.Helper()
	dir := t.TempDir()
	return &store{
		log:       slog.Default(),
		stateFile: filepath.Join(dir, "clipboard-history.json"),
		lockFile:  filepath.Join(dir, "clipboard-history.lock"),
		watchLock: filepath.Join(dir, "clipboard-watch.lock"),
		imagesDir: filepath.Join(dir, "clipboard-images"),
	}
}

func testManager(t *testing.T) *Manager {
	t.Helper()
	return &Manager{
		log:   slog.Default(),
		srv:   server.New(uint32(os.Getuid()), slog.Default()),
		store: testStore(t),
		state: &state{NextID: 1},
	}
}

func TestLoadMissingFile(t *testing.T) {
	st := testStore(t)
	s, warn, err := st.load()
	if err != nil || warn != "" {
		t.Fatalf("load: err=%v warn=%q", err, warn)
	}
	if s.NextID != 1 || len(s.Entries) != 0 {
		t.Fatalf("unexpected empty state: %+v", s)
	}
}

func TestLoadCorruptMovesAside(t *testing.T) {
	st := testStore(t)
	if err := os.WriteFile(st.stateFile, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	s, warn, err := st.load()
	if err != nil {
		t.Fatal(err)
	}
	if warn == "" {
		t.Fatal("expected corruption warning")
	}
	if len(s.Entries) != 0 {
		t.Fatalf("expected empty state, got %d entries", len(s.Entries))
	}
	if _, err := os.Stat(st.stateFile); !os.IsNotExist(err) {
		t.Fatal("corrupt file should have been moved aside")
	}
}

func TestLoadLegacyDropsInlineData(t *testing.T) {
	st := testStore(t)
	legacy := `{"nextId": 5, "entries": [{"id": 4, "hash": "h", "preview": "p", "text": "hello", "size": 5, "isImage": false, "mime": "text/plain", "pinned": false, "timestamp": 1, "data": "aGVsbG8="}]}`
	if err := os.WriteFile(st.stateFile, []byte(legacy), 0o644); err != nil {
		t.Fatal(err)
	}
	s, _, err := st.load()
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Entries) != 1 || s.Entries[0].Text != "hello" {
		t.Fatalf("legacy entry not loaded: %+v", s.Entries)
	}
	if err := st.save(s); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(st.stateFile)
	if err != nil {
		t.Fatal(err)
	}
	var reread map[string]any
	if err := json.Unmarshal(raw, &reread); err != nil {
		t.Fatal(err)
	}
	entries := reread["entries"].([]any)
	if _, has := entries[0].(map[string]any)["data"]; has {
		t.Fatal("saved state still carries legacy inline data")
	}
}

func TestSaveTrimsUnpinned(t *testing.T) {
	st := testStore(t)
	s := &state{NextID: 1}
	for i := 0; i < maxUnpinned+20; i++ {
		s.Entries = append(s.Entries, &Entry{ID: int64(i + 1), Hash: "h", Timestamp: int64(i)})
	}
	s.Entries = append(s.Entries, &Entry{ID: 999, Pinned: true, Timestamp: 0})
	if err := st.save(s); err != nil {
		t.Fatal(err)
	}
	unpinned := 0
	pinned := 0
	for _, e := range s.Entries {
		if e.Pinned {
			pinned++
		} else {
			unpinned++
		}
	}
	if unpinned != maxUnpinned || pinned != 1 {
		t.Fatalf("trim kept %d unpinned, %d pinned", unpinned, pinned)
	}
	// The oldest unpinned entries are the ones dropped.
	for _, e := range s.Entries {
		if !e.Pinned && e.Timestamp < 20 {
			t.Fatalf("expected oldest entries trimmed, found timestamp %d", e.Timestamp)
		}
	}
}

func TestPruneImages(t *testing.T) {
	st := testStore(t)
	if err := os.MkdirAll(st.imagesDir, 0o755); err != nil {
		t.Fatal(err)
	}
	hash := hashImage([]byte("blob"))
	kept := filepath.Join(st.imagesDir, hash+".png")
	stale := filepath.Join(st.imagesDir, hashImage([]byte("old"))+".png")
	foreign := filepath.Join(st.imagesDir, "not-a-hash.png")
	for _, p := range []string{kept, stale, foreign} {
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	s := &state{NextID: 1, Entries: []*Entry{{ID: 1, Hash: hash, IsImage: true, Path: kept}}}
	if err := st.save(s); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(kept); err != nil {
		t.Fatal("referenced image was pruned")
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("unreferenced image survived prune")
	}
	if _, err := os.Stat(foreign); err != nil {
		t.Fatal("non-hash-named file must not be touched")
	}
}

func TestSortEntriesPinnedFirstThenNewest(t *testing.T) {
	entries := []*Entry{
		{ID: 1, Timestamp: 10},
		{ID: 2, Timestamp: 30},
		{ID: 3, Timestamp: 20, Pinned: true},
		{ID: 4, Timestamp: 5, Pinned: true},
	}
	sortEntries(entries)
	got := []int64{entries[0].ID, entries[1].ID, entries[2].ID, entries[3].ID}
	want := []int64{3, 4, 2, 1}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("order = %v, want %v", got, want)
		}
	}
}

func TestTruncateRunes(t *testing.T) {
	if got := truncateRunes("héllo", 2); got != "hé" {
		t.Fatalf("got %q", got)
	}
	if got := truncateRunes("ab", 5); got != "ab" {
		t.Fatalf("got %q", got)
	}
}

func TestUpsertTextDedupBumps(t *testing.T) {
	m := testManager(t)
	if err := m.upsertTextLocked("hello"); err != nil {
		t.Fatal(err)
	}
	if err := m.upsertTextLocked("world"); err != nil {
		t.Fatal(err)
	}
	first := m.state.Entries[0]
	before := first.Timestamp
	m.findByHashLocked(hashText("hello")).Timestamp = before - 1000

	if err := m.upsertTextLocked("hello"); err != nil {
		t.Fatal(err)
	}
	if len(m.state.Entries) != 2 {
		t.Fatalf("dedup failed, %d entries", len(m.state.Entries))
	}
	e := m.findByHashLocked(hashText("hello"))
	if e.Timestamp < before {
		t.Fatal("dedup did not bump timestamp")
	}
}

func TestPinCapEnforced(t *testing.T) {
	m := testManager(t)
	for i := 0; i < maxPinned; i++ {
		m.state.Entries = append(m.state.Entries, &Entry{ID: int64(i + 1), Pinned: true})
	}
	m.state.Entries = append(m.state.Entries, &Entry{ID: 100})
	m.state.NextID = 101

	params, _ := json.Marshal(map[string]any{"id": 100})
	if _, err := m.handlePinEntry(params); err == nil {
		t.Fatal("expected pin cap error")
	}
	if _, err := m.handleUnpinEntry(mustID(1)); err != nil {
		t.Fatal(err)
	}
	if _, err := m.handlePinEntry(mustID(100)); err != nil {
		t.Fatalf("pin after unpin failed: %v", err)
	}
}

func TestClearHistoryKeepsPinned(t *testing.T) {
	m := testManager(t)
	m.state.Entries = []*Entry{
		{ID: 1, Pinned: true},
		{ID: 2},
		{ID: 3},
	}
	if _, err := m.handleClearHistory(nil); err != nil {
		t.Fatal(err)
	}
	if len(m.state.Entries) != 1 || m.state.Entries[0].ID != 1 {
		t.Fatalf("clear kept wrong entries: %+v", m.state.Entries)
	}
}

func TestSearchMatchesPreviewAndLimits(t *testing.T) {
	m := testManager(t)
	m.state.Entries = []*Entry{
		{ID: 1, Preview: "Hello World", Timestamp: 1},
		{ID: 2, Preview: "hello again", Timestamp: 2},
		{ID: 3, Preview: "other", Timestamp: 3},
	}
	params, _ := json.Marshal(map[string]any{"query": "hello", "limit": 1})
	res, err := m.handleSearch(params)
	if err != nil {
		t.Fatal(err)
	}
	entries := res.(map[string]any)["entries"].([]map[string]any)
	if len(entries) != 1 || entries[0]["id"].(int64) != 2 {
		t.Fatalf("unexpected search result: %+v", entries)
	}
}

func TestGetEntryReturnsTextData(t *testing.T) {
	m := testManager(t)
	m.state.Entries = []*Entry{{ID: 7, Text: "payload", Preview: "payload"}}
	res, err := m.handleGetEntry(mustID(7))
	if err != nil {
		t.Fatal(err)
	}
	out := res.(map[string]any)
	if out["data"].(string) != "cGF5bG9hZA==" {
		t.Fatalf("unexpected data: %v", out["data"])
	}
}

func TestGetEntryUnknownIsNull(t *testing.T) {
	m := testManager(t)
	res, err := m.handleGetEntry(mustID(42))
	if err != nil || res != nil {
		t.Fatalf("expected null result, got %v / %v", res, err)
	}
}

func TestExternalWriteIsPickedUp(t *testing.T) {
	m := testManager(t)
	if err := m.upsertTextLocked("mine"); err != nil {
		t.Fatal(err)
	}
	// Simulate the helper CLI rewriting the state file out-of-band.
	external := `{"nextId": 50, "entries": [{"id": 49, "hash": "x", "preview": "external", "text": "external", "size": 8, "mime": "text/plain", "timestamp": 99}]}`
	if err := os.WriteFile(m.store.stateFile, []byte(external), 0o644); err != nil {
		t.Fatal(err)
	}
	// Force a visible mtime difference even on coarse filesystems.
	m.store.lastMod = m.store.lastMod.Add(-1e9)

	res, err := m.handleGetHistory(nil)
	if err != nil {
		t.Fatal(err)
	}
	history := res.([]map[string]any)
	if len(history) != 1 || history[0]["preview"].(string) != "external" {
		t.Fatalf("external write not reloaded: %+v", history)
	}
}

func mustID(id int64) json.RawMessage {
	raw, _ := json.Marshal(map[string]any{"id": id})
	return raw
}
