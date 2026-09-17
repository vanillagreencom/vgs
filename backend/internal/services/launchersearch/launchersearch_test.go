package launchersearch

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"

	"vshell/backend/internal/protocol"
	"vshell/backend/internal/server"
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
		var f folder
		got, ok := f.score([]byte(tc.name), newNeedle(tc.query))
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

// stageBatches keeps the settle timer from firing during a test, so the test
// applies each batch itself once the changes it stages are all pending.
func stageBatches(t *testing.T) {
	restore := settleDelay
	settleDelay = time.Hour
	t.Cleanup(func() { settleDelay = restore })
}

// applyBatch waits until every watch in want is pending, ended by the kernel
// where want says so, and then applies the batch: the changes that raised
// those events are one batch by construction.
func applyBatch(t *testing.T, ix *index, want map[int32]bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		ix.watch.mu.Lock()
		ready := true
		for wd, ended := range want {
			byKernel, ok := ix.watch.pending[wd]
			if !ok || (ended && !byKernel) {
				ready = false
			}
		}
		ix.watch.mu.Unlock()
		if ready {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the events for %v never arrived", want)
		}
		time.Sleep(5 * time.Millisecond)
	}
	ix.applyChanges()
}

func TestChangesReachTheIndexWithoutAWalk(t *testing.T) {
	stageBatches(t)
	root := tree(t, "docs/old-match", "moving/inner/match-inside", "gone/match-under", "hollow/", "build/match-built")
	m := testManager(t)
	all := func(q string) request { return request{Roots: []string{root}, Query: q, Kind: "all"} }
	m.eventually(t, root, all("match"), []string{"build/match-built", "docs/old-match", "gone/match-under", "moving/inner/match-inside"})
	first := m.serving()
	at := func(rel string) int32 { return watchOf(first, filepath.Join(root, rel)) }

	for _, step := range []struct {
		name string
		// reports names the directories whose watches the change reaches, true
		// for one the change ends.
		reports func() map[int32]bool
		change  func()
		query   string
		want    []string
	}{
		{"a created file", func() map[int32]bool { return map[int32]bool{at("docs"): false} },
			func() { create(t, root, "docs/new-match") },
			"match", []string{"build/match-built", "docs/new-match", "docs/old-match", "gone/match-under", "moving/inner/match-inside"}},
		{"a removed directory takes its subtree", func() map[int32]bool { return map[int32]bool{at("."): false, at("gone"): true} },
			func() { os.RemoveAll(filepath.Join(root, "gone")) },
			"match", []string{"build/match-built", "docs/new-match", "docs/old-match", "moving/inner/match-inside"}},
		{"a moved directory is found under its new path", func() map[int32]bool { return map[int32]bool{at("."): false, at("docs"): false} },
			func() { os.Rename(filepath.Join(root, "moving"), filepath.Join(root, "docs/moved")) },
			"match", []string{"build/match-built", "docs/new-match", "docs/old-match", "docs/moved/inner/match-inside"}},
		{"a directory created with contents is walked", func() map[int32]bool { return map[int32]bool{at("."): false} },
			func() { create(t, root, "fresh/a/b/match-deep") },
			"match-deep", []string{"fresh/a/b/match-deep"}},
		{"a change inside a walked directory is watched", func() map[int32]bool { return map[int32]bool{at("fresh/a/b"): false} },
			func() { create(t, root, "fresh/a/b/match-later") },
			"match-", []string{"build/match-built", "docs/moved/inner/match-inside", "fresh/a/b/match-deep", "fresh/a/b/match-later"}},
		{"a change inside a moved directory is watched", func() map[int32]bool { return map[int32]bool{at("docs/moved/inner"): false} },
			func() { create(t, root, "docs/moved/inner/match-moved") },
			"match-", []string{"build/match-built", "fresh/a/b/match-deep", "fresh/a/b/match-later", "docs/moved/inner/match-inside", "docs/moved/inner/match-moved"}},
		{"a directory removed and made again in one batch loses its old entries", func() map[int32]bool { return map[int32]bool{at("fresh/a"): false, at("fresh/a/b"): true} },
			func() {
				os.RemoveAll(filepath.Join(root, "fresh/a/b"))
				create(t, root, "fresh/a/b/")
			}, "match-", []string{"build/match-built", "docs/moved/inner/match-inside", "docs/moved/inner/match-moved"}},
		{"and is watched again", func() map[int32]bool { return map[int32]bool{at("fresh/a/b"): false} },
			func() { create(t, root, "fresh/a/b/match-remade") },
			"match-", []string{"build/match-built", "docs/moved/inner/match-inside", "docs/moved/inner/match-moved", "fresh/a/b/match-remade"}},
		{"an empty directory removed and made again in one batch", func() map[int32]bool { return map[int32]bool{at("."): false, at("hollow"): true} },
			func() {
				os.Remove(filepath.Join(root, "hollow"))
				create(t, root, "hollow/")
			}, "hollow", []string{"hollow/"}},
		{"is watched again", func() map[int32]bool { return map[int32]bool{at("hollow"): false} },
			func() { create(t, root, "hollow/match-hollow") },
			"hollow", []string{"hollow/", "hollow/match-hollow"}},
		{"a directory renamed aside with a new one made in its place", func() map[int32]bool { return map[int32]bool{at("."): false} },
			func() {
				os.Rename(filepath.Join(root, "build"), filepath.Join(root, "build.old"))
				create(t, root, "build/")
			}, "match-built", []string{"build.old/match-built"}},
		{"watches the new directory, not the one renamed aside", func() map[int32]bool { return map[int32]bool{at("build"): false} },
			func() { create(t, root, "build/match-fresh") },
			"match-fresh", []string{"build/match-fresh"}},
		{"a file replaced by a directory of the same name", func() map[int32]bool { return map[int32]bool{at("docs"): false} },
			func() {
				os.Remove(filepath.Join(root, "docs/new-match"))
				create(t, root, "docs/new-match/match-within")
			}, "new-match", []string{"docs/new-match/"}},
	} {
		t.Log(step.name)
		reports := step.reports()
		step.change()
		applyBatch(t, first, reports)
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
	if first.degraded.Load() {
		t.Fatal("removing, moving and replacing directories marked the index as having missed changes")
	}
}

func TestAnUnreadableDirectoryKeepsItsChildren(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a directory whatever its mode")
	}
	stageBatches(t)
	root := tree(t, "locked/match-one", "locked/match-two")
	m := testManager(t)
	req := request{Roots: []string{root}, Query: "match", Kind: "files"}
	m.eventually(t, root, req, []string{"locked/match-one", "locked/match-two"})
	ix := m.serving()
	locked := filepath.Join(root, "locked")
	if err := os.Chmod(locked, 0o300); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(locked, 0o755) })
	// Writable but unreadable: the new name raises an event, and the listing
	// that follows fails.
	wd := watchOf(ix, locked)
	create(t, root, "locked/other")
	applyBatch(t, ix, map[int32]bool{wd: false})
	if live := ix.live(); live != 4 {
		t.Fatalf("the index holds %d live entries; want the root, the directory and both files it held", live)
	}
	if ix.degraded.Load() {
		t.Fatal("an unreadable directory that still reports changes marked the index")
	}
}

func TestAChildRemovedByItsParentInOneBatchIsNotWalked(t *testing.T) {
	root := tree(t, "parent/child/")
	m := testManager(t)
	m.relative(t, root, request{Roots: []string{root}, Query: "x", Kind: "files"})
	ix := m.serving()
	find := func(rel string) int32 {
		ix.mu.RLock()
		defer ix.mu.RUnlock()
		for pos := range ix.dirs {
			if ix.path(pos) == filepath.Join(root, rel) {
				return pos
			}
		}
		t.Fatalf("%s is not indexed", rel)
		return -1
	}
	parent, childPos := find("parent"), find("parent/child")
	ix.watch.writer.Lock()
	ix.mu.Lock()
	// The child lists a new directory, then the parent's listing no longer holds
	// the child, so the walk reaches a directory the batch already removed.
	walks := ix.reconcile(listing{job: dirJob{pos: childPos, path: filepath.Join(root, "parent/child")}, wd: -1, read: true,
		children: []child{{name: "new", path: filepath.Join(root, "parent/child/new"), isDir: true}}}, nil)
	walks = ix.reconcile(listing{job: dirJob{pos: parent, path: filepath.Join(root, "parent")}, wd: -1, read: true}, walks)
	ix.mu.Unlock()
	if err := ix.walk(context.Background(), walks); err != nil {
		t.Fatal(err)
	}
	ix.watch.writer.Unlock()
	if live := ix.live(); live != 2 {
		t.Fatalf("the index holds %d live entries; want the root and the parent", live)
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
	req := request{Roots: []string{root}, Query: "match", Kind: "files"}
	m.relative(t, root, req)
	for _, step := range []struct {
		name   string
		change func(*request)
		want   []string
	}{
		{"ignores", func(r *request) { r.Ignores = []string{"two"} }, []string{"one/match"}},
		{"ignoring mounts", func(r *request) { r.IgnoreMounts = true }, []string{"one/match"}},
		{"roots", func(r *request) { r.Roots = []string{filepath.Join(root, "one")} }, []string{"one/match"}},
	} {
		before := m.serving()
		step.change(&req)
		got := m.relative(t, root, req)
		if !slices.Equal(got, step.want) || m.serving() == before {
			t.Fatalf("changing %s: got %q from a replaced index %v; want %q from a new one", step.name, got, m.serving() != before, step.want)
		}
	}
}

func TestConfigResolvesHomeAndVariables(t *testing.T) {
	home := tree(t, "sub/")
	t.Setenv("HOME", home)
	t.Setenv("VGS_TEST_SET", "set")
	os.Unsetenv("VGS_TEST_UNSET")
	for _, tc := range []struct {
		name     string
		roots    []string
		ignores  []string
		want     []string
		prefixes []string
	}{
		{"a tilde root", []string{"~"}, nil, []string{home}, nil},
		{"a root under the tilde", []string{"~/sub"}, nil, []string{filepath.Join(home, "sub")}, nil},
		{"no roots", nil, nil, []string{home}, nil},
		{"a set variable", []string{"~"}, []string{"$VGS_TEST_SET/x"}, []string{home}, []string{filepath.Join(home, "set/x")}},
		{"an unset variable stays as written", []string{"~"}, []string{"$VGS_TEST_UNSET/x"}, []string{home}, []string{filepath.Join(home, "$VGS_TEST_UNSET/x")}},
	} {
		cfg, err := newConfig(tc.roots, tc.ignores, false)
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if !slices.Equal(cfg.roots, tc.want) || !slices.Equal(cfg.ignores.prefixes, tc.prefixes) {
			t.Errorf("%s: roots %q prefixes %q; want %q and %q", tc.name, cfg.roots, cfg.ignores.prefixes, tc.want, tc.prefixes)
		}
	}
}

func TestIgnoringMountsSkipsDirectoriesOnAnotherDevice(t *testing.T) {
	root := tree(t, "sub/", "file")
	var st unix.Stat_t
	if err := unix.Stat(root, &st); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		ignoreMounts bool
		want         []string
	}{
		{false, []string{"file", "sub"}},
		{true, []string{"file"}},
	} {
		cfg, err := newConfig([]string{root}, nil, tc.ignoreMounts)
		if err != nil {
			t.Fatal(err)
		}
		ix := newIndex(cfg, discard())
		// The root claims another device, as a mount point's parent does.
		l := ix.list(dirJob{pos: 0, path: root, dev: st.Dev + 1})
		var got []string
		for _, c := range l.children {
			got = append(got, c.name)
		}
		slices.Sort(got)
		if !slices.Equal(got, tc.want) {
			t.Errorf("ignoreMounts %v: got %q, want %q", tc.ignoreMounts, got, tc.want)
		}
	}
}

func TestAQueryReturnsAtMostTheLimitCap(t *testing.T) {
	var paths []string
	for i := 0; i < maxLimit+10; i++ {
		paths = append(paths, "match-"+strconv.Itoa(i))
	}
	root := tree(t, paths...)
	m := testManager(t)
	if got := m.relative(t, root, request{Roots: []string{root}, Query: "match", Kind: "files", Limit: 1000}); len(got) != maxLimit {
		t.Fatalf("got %d hits, want %d", len(got), maxLimit)
	}
}

func TestAWaitingQueryIsReplacedByANewerOneOfItsKind(t *testing.T) {
	srv := server.New(uint32(os.Getuid()), discard())
	m, err := Register(srv, discard())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(m.Close)
	ln, err := net.Listen("unix", "@vgs-launchersearch-test-"+strconv.Itoa(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go srv.Serve(ln)
	conn, err := net.Dial("unix", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	lines := bufio.NewScanner(conn)
	lines.Buffer(make([]byte, 0, 64*1024), 1<<20)

	root := tree(t, "match")
	// Hold the manager so the first query blocks in its handler, and the next
	// ones wait behind it.
	m.mu.Lock()
	locked := true
	defer func() {
		if locked {
			m.mu.Unlock()
		}
	}()
	for id := 1; id <= 3; id++ {
		params, _ := json.Marshal(request{Roots: []string{root}, Query: "match", Kind: "files"})
		frame, _ := json.Marshal(protocol.Request{ID: json.RawMessage(strconv.Itoa(id)), Method: "launcher.search.query", Params: params})
		if _, err := conn.Write(append(frame, '\n')); err != nil {
			t.Fatal(err)
		}
	}
	read := func() map[string]any {
		t.Helper()
		conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		if !lines.Scan() {
			t.Fatalf("no answer: %v", lines.Err())
		}
		var frame map[string]any
		if err := json.Unmarshal(lines.Bytes(), &frame); err != nil {
			t.Fatal(err)
		}
		return frame
	}
	first := read()
	if superseded, _ := first["result"].(map[string]any)["superseded"].(bool); !superseded {
		t.Fatalf("while one query ran, a waiting query of its kind was not replaced: %v", first)
	}
	m.mu.Unlock()
	locked = false
	for _, frame := range []map[string]any{read(), read()} {
		if frame["error"] != nil {
			t.Fatalf("a query failed: %v", frame)
		}
	}
}

func discard() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func TestAClosedWatcherNeverReachesAReusedDescriptor(t *testing.T) {
	dir := t.TempDir()
	w, err := newWatcher(discard())
	if err != nil {
		t.Fatal(err)
	}
	number := -1
	w.raw.Control(func(fd uintptr) { number = int(fd) })
	w.close()
	// Another inotify instance takes the released number, as the next index's
	// watcher or cloudsync's does.
	other, err := unix.InotifyInit1(unix.IN_CLOEXEC)
	if err != nil {
		t.Fatal(err)
	}
	if other != number {
		if err := unix.Dup3(other, number, unix.O_CLOEXEC); err != nil {
			t.Fatal(err)
		}
		unix.Close(other)
	}
	defer unix.Close(number)
	if _, err := w.add(dir); err == nil {
		t.Fatal("add on a closed watcher succeeded")
	}
	probe, err := unix.InotifyAddWatch(number, dir, unix.IN_CREATE)
	if err != nil {
		t.Fatal(err)
	}
	if probe != 1 {
		t.Fatalf("the reused instance's first own watch got descriptor %d: the closed watcher added one before it", probe)
	}
	w.remove(int32(probe))
	if _, err := unix.InotifyRmWatch(number, uint32(probe)); err != nil {
		t.Fatalf("the closed watcher removed the reused instance's watch: %v", err)
	}
}

func TestAReplacementWalksOnlyOnceTheIndexItReplacesHasReleasedItsWatches(t *testing.T) {
	restoreLimit, restoreAfter, restoreSettle := watchLimit, degradedRebuildAfter, settleDelay
	settleDelay = 10 * time.Millisecond
	t.Cleanup(func() { watchLimit, degradedRebuildAfter, settleDelay = restoreLimit, restoreAfter, restoreSettle })
	for _, tc := range []struct {
		name    string
		replace func(t *testing.T, m *Manager, root string, req request)
	}{
		{"other settings", func(t *testing.T, m *Manager, root string, req request) {
			req.Ignores = []string{"elsewhere"}
			m.relative(t, root, req)
		}},
		{"a worn-out rebuild", func(t *testing.T, m *Manager, root string, req request) {
			ix := m.serving()
			for i := 0; i < 8; i++ {
				os.Remove(filepath.Join(root, "f"+strconv.Itoa(i)))
			}
			deadline := time.Now().Add(5 * time.Second)
			for !ix.wornOut() && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond)
			}
			degradedRebuildAfter = 0
			m.relative(t, root, req)
			for m.serving() == ix && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond)
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			degradedRebuildAfter = restoreAfter
			paths := []string{"a/", "b/", "c/"}
			for i := 0; i < 8; i++ {
				paths = append(paths, "f"+strconv.Itoa(i))
			}
			root := tree(t, paths...)
			// Four watches for the root and its directories, on a budget of six: two
			// indexes watching at once would pass it.
			watchLimit = func() (int64, error) { return 12, nil }
			m := testManager(t)
			req := request{Roots: []string{root}, Query: "f", Kind: "files"}
			m.relative(t, root, req)
			old := m.serving()
			if old.unwatched.Load() || old.watches.Load() != 4 {
				t.Fatalf("the first index holds %d watches, unwatched %v", old.watches.Load(), old.unwatched.Load())
			}
			stillWatching := false
			watchLimit = func() (int64, error) {
				_, err := old.watch.add(root)
				stillWatching = err == nil
				return 12, nil
			}
			tc.replace(t, m, root, req)
			if next := m.serving(); next == old || next.unwatched.Load() {
				t.Fatal("the replacement was not built, or gave up its watches")
			}
			if stillWatching {
				t.Fatal("the replacement's walk started while the index it replaces still held its watches")
			}
		})
	}
}

func TestAnIndexPastItsWatchBudgetGivesUpItsWatchesAndStillAnswers(t *testing.T) {
	restoreLimit, restoreAfter := watchLimit, degradedRebuildAfter
	t.Cleanup(func() { watchLimit, degradedRebuildAfter = restoreLimit, restoreAfter })
	const budget = 3
	watchLimit = func() (int64, error) { return 2 * budget, nil }
	var paths []string
	for i := 0; i < 40; i++ {
		paths = append(paths, "d"+strconv.Itoa(i)+"/match")
	}
	root := tree(t, paths...)
	var logged bytes.Buffer
	m := newManager(slog.New(slog.NewTextHandler(&logged, nil)))
	t.Cleanup(m.Close)
	req := request{Roots: []string{root}, Query: "match", Kind: "files"}
	if got := m.relative(t, root, req); len(got) != 40 {
		t.Fatalf("got %d hits, want 40", len(got))
	}
	ix := m.serving()
	if !ix.unwatched.Load() || !ix.degraded.Load() {
		t.Fatal("an index past its watch budget kept watching")
	}
	if held := ix.watches.Load(); held > budget+int64(walkWorkers()) {
		t.Fatalf("the index took %d watches on a budget of %d", held, budget)
	}
	if _, err := ix.watch.add(root); err == nil {
		t.Fatal("the index still holds its inotify instance, and with it every watch")
	}
	if n := strings.Count(logged.String(), "level=WARN"); n != 1 {
		t.Fatalf("logged %d warnings, want one: %s", n, logged.String())
	}

	degradedRebuildAfter = 0
	m.relative(t, root, req)
	deadline := time.Now().Add(5 * time.Second)
	for m.serving() == ix && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if next := m.serving(); next == ix || next.watch != nil {
		t.Fatal("the rebuild of an index that ran out of watches took watches again")
	}
}

// event is one inotify event record for wd with mask.
func event(wd int32, mask uint32) []byte {
	buf := make([]byte, unix.SizeofInotifyEvent)
	ev := (*unix.InotifyEvent)(unsafe.Pointer(&buf[0]))
	ev.Wd = wd
	ev.Mask = mask
	return buf
}

func watchOf(ix *index, path string) int32 {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	for wd, positions := range ix.byWd {
		if ix.path(positions[0]) == path {
			return wd
		}
	}
	return -1
}

func TestAnUnmountMarksTheIndex(t *testing.T) {
	root := tree(t, "kept/match")
	m := testManager(t)
	m.relative(t, root, request{Roots: []string{root}, Query: "match", Kind: "files"})
	ix := m.serving()
	ix.noteEvents(event(watchOf(ix, filepath.Join(root, "kept")), unix.IN_UNMOUNT))
	if !ix.degraded.Load() {
		t.Fatal("the index kept claiming to see every change under an unmounted file system")
	}
}

func TestAWatchTheKernelEndsIsTakenAgain(t *testing.T) {
	for _, tc := range []struct {
		name     string
		readable bool
	}{
		{"on a directory it can list again", true},
		{"on a directory it can no longer list", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if !tc.readable && os.Geteuid() == 0 {
				t.Skip("root reads a directory whatever its mode")
			}
			stageBatches(t)
			root := tree(t, "kept/match")
			m := testManager(t)
			req := request{Roots: []string{root}, Query: "match", Kind: "files"}
			m.relative(t, root, req)
			ix := m.serving()
			kept := filepath.Join(root, "kept")
			if !tc.readable {
				if err := os.Chmod(kept, 0o300); err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { os.Chmod(kept, 0o755) })
			}
			// End the watch behind the index's back; the kernel reports it as it
			// reports any watch it ends.
			wd := watchOf(ix, kept)
			ix.watch.raw.Control(func(fd uintptr) { unix.InotifyRmWatch(int(fd), uint32(wd)) })
			applyBatch(t, ix, map[int32]bool{wd: true})
			if !tc.readable {
				if !ix.degraded.Load() {
					t.Fatal("a directory that can no longer be listed or watched left the index claiming to see every change")
				}
				return
			}
			next := watchOf(ix, kept)
			if next < 0 || next == wd {
				t.Fatalf("the directory is watched by %d after its watch %d ended", next, wd)
			}
			create(t, root, "kept/match-after")
			applyBatch(t, ix, map[int32]bool{next: false})
			m.eventually(t, root, req, []string{"kept/match", "kept/match-after"})
			if ix.degraded.Load() || m.serving() != ix {
				t.Fatal("a directory still there was answered by a fresh walk instead of being watched again")
			}
		})
	}
}

func TestAWornOutIndexIsWalkedAgain(t *testing.T) {
	restoreSettle, restoreAfter := settleDelay, degradedRebuildAfter
	settleDelay = 10 * time.Millisecond
	t.Cleanup(func() { settleDelay, degradedRebuildAfter = restoreSettle, restoreAfter })
	root := tree(t, "a", "b", "c", "d", "e", "f", "match")
	m := testManager(t)
	req := request{Roots: []string{root}, Query: "match", Kind: "files"}
	m.relative(t, root, req)
	first := m.serving()
	for _, name := range []string{"a", "b", "c", "d", "e", "f"} {
		os.Remove(filepath.Join(root, name))
	}
	deadline := time.Now().Add(5 * time.Second)
	for !first.wornOut() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if first.degraded.Load() {
		t.Fatal("removing files marked the index as having missed changes")
	}
	degradedRebuildAfter = 0
	m.relative(t, root, req)
	for m.serving() == first && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if m.serving() == first {
		t.Fatal("an index holding more dead entries than live ones was not walked again")
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
