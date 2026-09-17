package launchersearch

import (
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// tree creates each path under a fresh root; a path ending in "/" is a
// directory, anything else an empty file.
func tree(t *testing.T, paths ...string) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range paths {
		create(t, root, p)
	}
	return root
}

func create(t *testing.T, root, p string) {
	t.Helper()
	full := filepath.Join(root, p)
	if strings.HasSuffix(p, "/") {
		if err := os.MkdirAll(full, 0o755); err != nil {
			t.Fatal(err)
		}
		return
	}
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, nil, 0o644); err != nil {
		t.Fatal(err)
	}
}

func testManager(t *testing.T) *Manager {
	t.Helper()
	m := newManager(slog.New(slog.NewTextHandler(io.Discard, nil)))
	t.Cleanup(m.Close)
	return m
}

// serving is the index answering queries now.
func (m *Manager) serving() *index {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.current
}

type request struct {
	Roots        []string `json:"roots"`
	Ignores      []string `json:"ignores,omitempty"`
	IgnoreMounts bool     `json:"ignoreMounts,omitempty"`
	Query        string   `json:"query"`
	Kind         string   `json:"kind"`
	Limit        int      `json:"limit,omitempty"`
}

// relative runs one query and returns its hits' paths relative to root.
func (m *Manager) relative(t *testing.T, root string, req request) []string {
	t.Helper()
	raw, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	result, err := m.handleQuery(raw)
	if err != nil {
		t.Fatalf("query %+v: %v", req, err)
	}
	hits := result.(map[string]any)["hits"].([]hit)
	out := make([]string, 0, len(hits))
	for _, h := range hits {
		rel, err := filepath.Rel(root, h.Path)
		if err != nil {
			t.Fatal(err)
		}
		if h.IsDir {
			rel += "/"
		}
		out = append(out, rel)
	}
	return out
}

// eventually polls a query until it returns the paths in want, in any order,
// since a delta reaches the index after the settle delay.
func (m *Manager) eventually(t *testing.T, root string, req request, want []string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var got []string
	for time.Now().Before(deadline) {
		got = m.relative(t, root, req)
		if sameSet(got, want) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("query %q kind %s: got %q, want %q", req.Query, req.Kind, got, want)
}

func TestScoreRanksSubstringsAboveSubsequences(t *testing.T) {
	for _, tc := range []struct {
		name, query string
		want        float64
		match       bool
	}{
		{"firefox", "fire", 1000 - 0 - 3*0.15, true},
		{"FireFox", "fox", 1000 - 4*2 - 4*0.15, true},
		{"my-firefox", "fire", 1000 - 3*2 - 6*0.15, true},
		{"f_i_r_e", "fire", 650 - 3*4 - 3*0.1, true},
		{"fier", "fire", 0, false},
		{"Überblick", "über", 1000 - 5*0.15, true},
		{"naïve.txt", "nve", 650 - 2*4 - 6*0.1, true},
	} {
		needle := []rune(strings.ToLower(tc.query))
		ascii := []byte(nil)
		if isASCII([]byte(tc.query)) {
			ascii = []byte(strings.ToLower(tc.query))
		}
		got, ok := score([]byte(tc.name), needle, ascii)
		if ok != tc.match || (ok && got != tc.want) {
			t.Errorf("score(%q, %q) = %v, %v; want %v, %v", tc.name, tc.query, got, ok, tc.want, tc.match)
		}
	}
}

func TestQueryRanksAndFiltersByKind(t *testing.T) {
	root := tree(t,
		"notes/firefox.txt",
		"firefox/",
		"src/f_i_r_e.go",
		"deep/nest/fire",
		"unrelated.md",
	)
	m := testManager(t)
	for _, tc := range []struct {
		kind string
		want []string
	}{
		{"files", []string{"deep/nest/fire", "notes/firefox.txt", "src/f_i_r_e.go"}},
		{"folders", []string{"firefox/"}},
		{"all", []string{"deep/nest/fire", "firefox/", "notes/firefox.txt", "src/f_i_r_e.go"}},
	} {
		got := m.relative(t, root, request{Roots: []string{root}, Query: "fire", Kind: tc.kind})
		if !slices.Equal(got, tc.want) {
			t.Errorf("kind %s: got %q, want %q", tc.kind, got, tc.want)
		}
	}
	if got := m.relative(t, root, request{Roots: []string{root}, Query: "fire", Kind: "all", Limit: 2}); len(got) != 2 {
		t.Errorf("limit 2 returned %q", got)
	}
}

func TestEqualScoresRankTheNewerEntryFirst(t *testing.T) {
	root := tree(t, "a/report", "b/report")
	old := time.Now().Add(-48 * time.Hour)
	if err := os.Chtimes(filepath.Join(root, "a/report"), old, old); err != nil {
		t.Fatal(err)
	}
	m := testManager(t)
	got := m.relative(t, root, request{Roots: []string{root}, Query: "report", Kind: "files"})
	if want := []string{"b/report", "a/report"}; !slices.Equal(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestIgnoreRulesHideEntriesAndEverythingUnderThem(t *testing.T) {
	for _, tc := range []struct {
		name    string
		ignores func(root string) []string
		want    []string
	}{
		{"nothing ignored", func(string) []string { return nil },
			[]string{"keep/match", "keep/node_modules/match", "keep/share/Trash/match", "outside/match"}},
		{"a bare name at any depth", func(string) []string { return []string{"node_modules"} },
			[]string{"keep/match", "keep/share/Trash/match", "outside/match"}},
		{"a relative path joined to the root", func(string) []string { return []string{"keep/share/Trash"} },
			[]string{"keep/match", "keep/node_modules/match", "outside/match"}},
		{"an absolute path", func(root string) []string { return []string{filepath.Join(root, "outside")} },
			[]string{"keep/match", "keep/node_modules/match", "keep/share/Trash/match"}},
		{"a relative path is not a bare name", func(string) []string { return []string{"share/Trash"} },
			[]string{"keep/match", "keep/node_modules/match", "keep/share/Trash/match", "outside/match"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := tree(t, "keep/match", "keep/node_modules/match", "keep/share/Trash/match", "outside/match")
			m := testManager(t)
			got := m.relative(t, root, request{Roots: []string{root}, Ignores: tc.ignores(root), Query: "match", Kind: "files"})
			slices.Sort(got)
			if !slices.Equal(got, tc.want) {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestARootUnderAnIgnoredNameReturnsNothing(t *testing.T) {
	root := tree(t, ".cache/app/match")
	m := testManager(t)
	got := m.relative(t, root, request{Roots: []string{filepath.Join(root, ".cache/app")}, Ignores: []string{".cache"}, Query: "match", Kind: "files"})
	if len(got) != 0 {
		t.Fatalf("got %q, want nothing", got)
	}
}

func TestSymlinksAreNotIndexed(t *testing.T) {
	root := tree(t, "real/match")
	if err := os.Symlink(filepath.Join(root, "real"), filepath.Join(root, "linkdir")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "real/match"), filepath.Join(root, "match-link")); err != nil {
		t.Fatal(err)
	}
	m := testManager(t)
	got := m.relative(t, root, request{Roots: []string{root}, Query: "match", Kind: "all"})
	if want := []string{"real/match"}; !slices.Equal(got, want) {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestQueryRefusesAnUnknownKindAndMissingRoots(t *testing.T) {
	root := tree(t, "a")
	m := testManager(t)
	for _, tc := range []struct {
		req  request
		want string
	}{
		{request{Roots: []string{root}, Query: "a", Kind: "text"}, `unknown search kind "text"`},
		{request{Roots: []string{filepath.Join(root, "missing")}, Query: "a", Kind: "files"}, errNoRoots.Error()},
	} {
		raw, _ := json.Marshal(tc.req)
		if _, err := m.handleQuery(raw); err == nil || err.Error() != tc.want {
			t.Errorf("%+v: err = %v, want %q", tc.req, err, tc.want)
		}
	}
}

func TestChangesReachTheIndexWithoutAWalk(t *testing.T) {
	restore := settleDelay
	settleDelay = 10 * time.Millisecond
	t.Cleanup(func() { settleDelay = restore })

	root := tree(t, "docs/old-match", "moving/inner/match-inside", "gone/match-under")
	m := testManager(t)
	all := func(q string) request { return request{Roots: []string{root}, Query: q, Kind: "all"} }
	m.eventually(t, root, all("match"), []string{"docs/old-match", "gone/match-under", "moving/inner/match-inside"})
	first := m.serving()

	for _, step := range []struct {
		name   string
		change func()
		query  string
		want   []string
	}{
		{"a created file", func() { create(t, root, "docs/new-match") },
			"match", []string{"docs/new-match", "docs/old-match", "gone/match-under", "moving/inner/match-inside"}},
		{"a removed directory takes its subtree", func() { os.RemoveAll(filepath.Join(root, "gone")) },
			"match", []string{"docs/new-match", "docs/old-match", "moving/inner/match-inside"}},
		{"a moved directory is found under its new path", func() {
			os.Rename(filepath.Join(root, "moving"), filepath.Join(root, "docs/moved"))
		}, "match", []string{"docs/new-match", "docs/old-match", "docs/moved/inner/match-inside"}},
		{"a directory created with contents is walked", func() { create(t, root, "fresh/a/b/match-deep") },
			"match", []string{"docs/new-match", "docs/old-match", "docs/moved/inner/match-inside", "fresh/a/b/match-deep"}},
		{"a change inside a walked directory is watched", func() { create(t, root, "fresh/a/b/match-later") },
			"match-", []string{"docs/moved/inner/match-inside", "fresh/a/b/match-deep", "fresh/a/b/match-later"}},
		{"a change inside a moved directory is watched", func() { create(t, root, "docs/moved/inner/match-moved") },
			"match-", []string{"fresh/a/b/match-deep", "fresh/a/b/match-later", "docs/moved/inner/match-inside", "docs/moved/inner/match-moved"}},
	} {
		step.change()
		t.Log(step.name)
		m.eventually(t, root, all(step.query), step.want)
	}
	if m.serving() != first {
		t.Fatal("a change replaced the index with a fresh walk instead of reaching it as a delta")
	}
	// Search results stat every hit, which hides a removed entry the index still
	// holds; the count of live entries does not.
	onDisk := 0
	filepath.WalkDir(root, func(string, os.DirEntry, error) error { onDisk++; return nil })
	if live := first.live(); live != onDisk {
		t.Fatalf("the index holds %d live entries for %d on disk", live, onDisk)
	}
}

func sameSet(a, b []string) bool {
	a, b = slices.Clone(a), slices.Clone(b)
	slices.Sort(a)
	slices.Sort(b)
	return slices.Equal(a, b)
}

func TestNewSettingsReplaceTheIndex(t *testing.T) {
	root := tree(t, "one/match", "two/match")
	m := testManager(t)
	req := request{Roots: []string{filepath.Join(root, "one")}, Query: "match", Kind: "files"}
	if got := m.relative(t, root, req); !slices.Equal(got, []string{"one/match"}) {
		t.Fatalf("first roots: got %q", got)
	}
	req.Roots = []string{filepath.Join(root, "two")}
	if got := m.relative(t, root, req); !slices.Equal(got, []string{"two/match"}) {
		t.Fatalf("second roots: got %q", got)
	}
}

// overflow is the event the kernel queues when it dropped events.
func overflow() []byte {
	buf := make([]byte, unix.SizeofInotifyEvent)
	ev := (*unix.InotifyEvent)(unsafe.Pointer(&buf[0]))
	ev.Wd = -1
	ev.Mask = unix.IN_Q_OVERFLOW
	return buf
}

func TestAnIndexThatMissedChangesIsWalkedAgain(t *testing.T) {
	restore := degradedRebuildAfter
	t.Cleanup(func() { degradedRebuildAfter = restore })
	root := tree(t, "match-before")
	m := testManager(t)
	req := request{Roots: []string{root}, Query: "match", Kind: "files"}
	if got := m.relative(t, root, req); !slices.Equal(got, []string{"match-before"}) {
		t.Fatalf("got %q", got)
	}
	stale := m.serving()
	// Stop the watches, then lose a change the way an overflowing queue does.
	stale.watch.close()
	stale.noteEvents(overflow())
	create(t, root, "match-missed")

	degradedRebuildAfter = time.Hour
	if got := m.relative(t, root, req); !slices.Equal(got, []string{"match-before"}) || m.serving() != stale {
		t.Fatalf("within the rebuild interval: got %q from a replaced index %v", got, m.serving() != stale)
	}
	degradedRebuildAfter = 0
	m.eventually(t, root, req, []string{"match-before", "match-missed"})
	if m.serving() == stale {
		t.Fatal("the missed change was answered without a fresh walk")
	}
}

func TestPrepareStartsTheWalkWithoutWaiting(t *testing.T) {
	root := tree(t, "match")
	m := testManager(t)
	raw, _ := json.Marshal(request{Roots: []string{root}})
	if _, err := m.handlePrepare(raw); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if m.serving() != nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("prepare never produced an index")
}

func TestQueriesCoalesceOnlyWithinTheirKind(t *testing.T) {
	key := func(kind string) string { return queryKey(json.RawMessage(`{"kind":"` + kind + `","query":"x"}`)) }
	if key("files") != key("files") {
		t.Fatal("two files queries must share a slot, so the newer replaces the one waiting")
	}
	if key("files") == key("folders") || key("files") == key("all") {
		t.Fatal("a folders or all query must not replace a files query")
	}
	if got := queryKey(json.RawMessage(`not json`)); got != "" {
		t.Fatalf("unreadable params got key %q; want none, so the handler reports them", got)
	}
}
