package cloudsync

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"vshell/backend/internal/server"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
}

// testManager uses a temporary HOME and does not start rclone.
func testManager(t *testing.T) *Manager {
	t.Helper()
	t.Setenv("HOME", t.TempDir())

	st, err := newStore()
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	m := &Manager{
		srv:      server.New(uint32(os.Getuid()), discardLogger()),
		log:      discardLogger(),
		binary:   "rclone",
		client:   newRCClient(),
		store:    st,
		statuses: map[string]*FolderStatus{},
		jobs:     map[string]*activeJob{},
		timers:   map[string]*time.Timer{},
		failures: map[string]int{},
	}
	m.shutdown, m.stopTasks = context.WithCancel(context.Background())
	t.Cleanup(m.stopTasks)
	m.daemon = newRCD("rclone", m.client, nil, nil)
	return m
}

func TestPathsOverlap(t *testing.T) {
	cases := []struct {
		name string
		a, b string
		want bool
	}{
		{"identical", "/home/u/Docs", "/home/u/Docs", true},
		{"child", "/home/u/Docs", "/home/u/Docs/Work", true},
		{"parent", "/home/u/Docs/Work", "/home/u/Docs", true},
		{"siblings", "/home/u/Docs", "/home/u/Photos", false},
		{"prefix but not a path component", "/home/u/Docs", "/home/u/Docs2", false},
		{"empty", "", "/home/u/Docs", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := pathsOverlap(tc.a, tc.b); got != tc.want {
				t.Fatalf("pathsOverlap(%q,%q) = %v, want %v", tc.a, tc.b, got, tc.want)
			}
		})
	}
}

func TestRemotePathsOverlap(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"Docs", "Docs", true},
		{"Docs", "Docs/Work", true},
		{"Docs", "Photos", false},
		{"", "Docs", true},
		{"Docs", "Docs2", false},
	}
	for _, tc := range cases {
		if got := remotePathsOverlap(tc.a, tc.b); got != tc.want {
			t.Fatalf("remotePathsOverlap(%q,%q) = %v, want %v", tc.a, tc.b, got, tc.want)
		}
	}
}

func TestValidateFolderRejectsHomeAndOverlaps(t *testing.T) {
	m := testManager(t)
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("UserHomeDir: %v", err)
	}

	if err := m.validateFolder(Folder{ID: "a", LocalPath: home, Mode: ModeBackup}); err == nil {
		t.Fatal("expected syncing the whole home directory to be rejected")
	}

	docs := filepath.Join(home, "Docs")
	if err := os.MkdirAll(filepath.Join(docs, "Work"), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	existing := Folder{ID: "existing", Name: "Docs", Remote: "gdrive", RemotePath: "Docs", LocalPath: docs, Mode: ModeBackup}
	if err := m.store.putFolder(existing); err != nil {
		t.Fatalf("putFolder: %v", err)
	}

	nested := Folder{ID: "new", Remote: "gdrive", RemotePath: "Other", LocalPath: filepath.Join(docs, "Work"), Mode: ModeBackup}
	if err := m.validateFolder(nested); err == nil {
		t.Fatal("expected an overlapping local folder to be rejected")
	}

	sameRemote := Folder{ID: "new2", Remote: "gdrive", RemotePath: "Docs/Sub", LocalPath: filepath.Join(home, "Elsewhere"), Mode: ModeBackup}
	if err := os.MkdirAll(sameRemote.LocalPath, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := m.validateFolder(sameRemote); err == nil {
		t.Fatal("expected an overlapping cloud folder to be rejected")
	}

	ok := Folder{ID: "new3", Remote: "gdrive", RemotePath: "Photos", LocalPath: filepath.Join(home, "Elsewhere"), Mode: ModeBackup}
	if err := m.validateFolder(ok); err != nil {
		t.Fatalf("expected a non-overlapping folder to validate, got %v", err)
	}
}

func TestNormalizeFolder(t *testing.T) {
	m := testManager(t)
	home, _ := os.UserHomeDir()
	local := filepath.Join(home, "Docs")
	if err := os.MkdirAll(local, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	twoWay, err := m.normalizeFolder(Folder{Remote: "gdrive:", RemotePath: "/Docs/", LocalPath: local, Mode: ModeTwoWay})
	if err != nil {
		t.Fatalf("normalizeFolder: %v", err)
	}
	if twoWay.Remote != "gdrive" || twoWay.RemotePath != "Docs" {
		t.Fatalf("remote not canonicalized: %+v", twoWay)
	}
	if twoWay.ID == "" || twoWay.Name != "Docs" || twoWay.MaxDelete != -1 {
		t.Fatalf("defaults not applied: %+v", twoWay)
	}
	if twoWay.ResyncDone {
		t.Fatal("a new two-way folder must not claim an established baseline")
	}

	oneWay, err := m.normalizeFolder(Folder{Remote: "gdrive", RemotePath: "Docs", LocalPath: local, Mode: ModeBackup})
	if err != nil {
		t.Fatalf("normalizeFolder: %v", err)
	}
	if !oneWay.ResyncDone {
		t.Fatal("one-way folders never need a baseline")
	}

	stream, err := m.normalizeFolder(Folder{Remote: "gdrive", RemotePath: "Docs", Name: "My Drive", Mode: ModeStream})
	if err != nil {
		t.Fatalf("normalizeFolder(stream): %v", err)
	}
	if !strings.HasPrefix(stream.LocalPath, m.store.mountRoot) {
		t.Fatalf("stream folder should live under the mount root, got %q", stream.LocalPath)
	}
	if stream.RealTime || stream.IntervalSeconds != 0 {
		t.Fatalf("stream folders are never scheduled or watched: %+v", stream)
	}

	if _, err := m.normalizeFolder(Folder{Remote: "gdrive", LocalPath: local, Mode: "sideways"}); err == nil {
		t.Fatal("expected an unknown mode to be rejected")
	}
	if _, err := m.normalizeFolder(Folder{Remote: "gdrive", LocalPath: "relative/path", Mode: ModeBackup}); err == nil {
		t.Fatal("expected a relative local path to be rejected")
	}
}

func TestBuildSyncParams(t *testing.T) {
	m := testManager(t)
	home, _ := os.UserHomeDir()
	local := filepath.Join(home, "Docs")
	settings := defaultSettings()

	backup := Folder{ID: "f1", Remote: "gdrive", RemotePath: "Docs", LocalPath: local, Mode: ModeBackup, MaxDelete: 100}
	params, err := m.buildSyncParams(backup, settings, statsGroup(backup.ID), syncOptions{})
	if err != nil {
		t.Fatalf("buildSyncParams: %v", err)
	}
	if params["srcFs"] != local || params["dstFs"] != "gdrive:Docs" {
		t.Fatalf("backup direction wrong: %+v", params)
	}
	config := params["_config"].(map[string]any)
	if config["BackupDir"] != backup.remoteTrash() {
		t.Fatalf("backup mode must trash to the cloud side, got %v", config["BackupDir"])
	}
	if config["MaxDelete"] != 100 {
		t.Fatalf("MaxDelete not applied: %v", config["MaxDelete"])
	}

	restore := backup
	restore.Mode = ModeRestore
	params, err = m.buildSyncParams(restore, settings, statsGroup(restore.ID), syncOptions{})
	if err != nil {
		t.Fatalf("buildSyncParams: %v", err)
	}
	if params["srcFs"] != "gdrive:Docs" || params["dstFs"] != local {
		t.Fatalf("restore direction wrong: %+v", params)
	}
	if params["_config"].(map[string]any)["BackupDir"] != m.store.localTrash(restore.ID) {
		t.Fatal("restore mode must trash to the local side")
	}

	twoWay := Folder{ID: "f2", Remote: "gdrive", RemotePath: "Docs", LocalPath: local, Mode: ModeTwoWay, MaxDelete: -1}
	params, err = m.buildSyncParams(twoWay, settings, statsGroup(twoWay.ID), syncOptions{Resync: true, ResyncMode: "path2"})
	if err != nil {
		t.Fatalf("buildSyncParams: %v", err)
	}
	if params["path1"] != local || params["path2"] != "gdrive:Docs" {
		t.Fatalf("bisync paths wrong: %+v", params)
	}
	for _, key := range []string{"resilient", "recover", "backupDir1", "backupDir2", "workdir", "conflictResolve"} {
		if _, ok := params[key]; !ok {
			t.Fatalf("bisync is missing its %s safety parameter", key)
		}
	}
	if params["resync"] != true || params["resyncMode"] != "path2" {
		t.Fatalf("resync not requested correctly: %+v", params)
	}
	if params["conflictResolve"] != "none" {
		t.Fatalf("default conflict handling must keep both sides, got %v", params["conflictResolve"])
	}

	// A run without an explicit resync must never smuggle one in.
	params, _ = m.buildSyncParams(twoWay, settings, statsGroup(twoWay.ID), syncOptions{})
	if _, ok := params["resync"]; ok {
		t.Fatal("a normal two-way run must not pass resync")
	}

	filtered := backup
	filtered.Excludes = []string{"*.tmp"}
	params, _ = m.buildSyncParams(filtered, settings, statsGroup(filtered.ID), syncOptions{})
	if params["_filter"].(map[string]any)["ExcludeRule"].([]string)[0] != "*.tmp" {
		t.Fatalf("excludes not passed through: %+v", params["_filter"])
	}

	if _, err := m.buildSyncParams(Folder{Mode: ModeStream}, settings, "g", syncOptions{}); err == nil {
		t.Fatal("stream folders have no sync params")
	}
}

func TestRemoteTrashSitsBesideTheSyncedTree(t *testing.T) {
	f := Folder{ID: "abc", Remote: "gdrive", RemotePath: "Documents/Work"}
	if got, want := f.remoteTrash(), "gdrive:Documents/.vgs-trash/abc"; got != want {
		t.Fatalf("remoteTrash = %q, want %q", got, want)
	}
	root := Folder{ID: "abc", Remote: "gdrive"}
	if got, want := root.remoteTrash(), "gdrive:.vgs-trash/abc"; got != want {
		t.Fatalf("remoteTrash = %q, want %q", got, want)
	}
}

func TestBandwidthRate(t *testing.T) {
	cases := []struct{ up, down, want string }{
		{"", "", "off"},
		{"1M", "", "1M:off"},
		{"", "500k", "off:500k"},
		{"1M", "500k", "1M:500k"},
		{" 1M ", " 500k ", "1M:500k"},
	}
	for _, tc := range cases {
		if got := bandwidthRate(tc.up, tc.down); got != tc.want {
			t.Fatalf("bandwidthRate(%q,%q) = %q, want %q", tc.up, tc.down, got, tc.want)
		}
	}
}

func TestStoreRoundTrip(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	st, err := newStore()
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	local := filepath.Join(os.Getenv("HOME"), "Docs")
	if err := os.MkdirAll(local, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	folder := Folder{ID: "f1", Name: "Docs", Remote: "gdrive", RemotePath: "Docs", LocalPath: local, Mode: ModeTwoWay, IntervalSeconds: 900}
	if err := st.putFolder(folder); err != nil {
		t.Fatalf("putFolder: %v", err)
	}
	settings := st.snapshotSettings()
	settings.BandwidthUp = "2M"
	if err := st.putSettings(settings); err != nil {
		t.Fatalf("putSettings: %v", err)
	}

	reloaded, err := newStore()
	if err != nil {
		t.Fatalf("newStore(reload): %v", err)
	}
	got, ok := reloaded.folder("f1")
	if !ok || got.RemotePath != "Docs" || got.IntervalSeconds != 900 {
		t.Fatalf("folder did not round-trip: %+v ok=%v", got, ok)
	}
	if reloaded.snapshotSettings().BandwidthUp != "2M" {
		t.Fatal("settings did not round-trip")
	}
	// Defaults must apply when the config omits these fields.
	if reloaded.snapshotSettings().Transfers != defaultSettings().Transfers {
		t.Fatal("missing settings should fall back to defaults")
	}

	if _, err := reloaded.deleteFolder("f1"); err != nil {
		t.Fatalf("deleteFolder: %v", err)
	}
	if _, ok := reloaded.folder("f1"); ok {
		t.Fatal("folder should be gone")
	}
	if _, err := reloaded.deleteFolder("nope"); err == nil {
		t.Fatal("deleting an unknown folder should error")
	}
}

func TestStoreSurvivesCorruptConfig(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	configDir := filepath.Join(home, ".config", "vshell")
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "cloudsync.json"), []byte("{ not json"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	st, err := newStore()
	if err != nil {
		t.Fatalf("a corrupt config must not stop the service: %v", err)
	}
	if len(st.snapshotFolders()) != 0 || st.snapshotSettings().Transfers != defaultSettings().Transfers {
		t.Fatal("expected defaults after a corrupt config")
	}
	if len(st.snapshotWarnings()) == 0 {
		t.Fatal("a corrupt config should be surfaced as a load warning")
	}
}

func TestApplyStatsMapsProgress(t *testing.T) {
	m := testManager(t)
	folder := Folder{ID: "f1", Name: "Docs", Mode: ModeBackup}
	job := &activeJob{FolderID: folder.ID, Group: statsGroup(folder.ID)}

	m.applyStats(folder, job, rcStats{
		Bytes: 512, TotalBytes: 2048, Speed: 128, ETA: 12, Transfers: 3, Checks: 9, Errors: 0,
		Transferring: []rcTransferring{{Name: "sub/dir/report.pdf", Size: 100, Bytes: 40, Percentage: 40, Speed: 64, SrcFs: "/home/u/Docs"}},
	})

	m.mu.Lock()
	st := m.statusLocked(folder.ID)
	m.mu.Unlock()

	if st.State != StateSyncing || st.Bytes != 512 || st.TotalBytes != 2048 || st.Speed != 128 {
		t.Fatalf("stats not applied: %+v", st)
	}
	if len(st.Transferring) != 1 {
		t.Fatalf("expected one active transfer, got %d", len(st.Transferring))
	}
	tr := st.Transferring[0]
	if tr.Name != "report.pdf" {
		t.Fatalf("transfer name should be the basename, got %q", tr.Name)
	}
	if tr.Direction != "up" || tr.FolderName != "Docs" || tr.Percentage != 40 {
		t.Fatalf("transfer mapped wrong: %+v", tr)
	}
}

func TestTransferDirection(t *testing.T) {
	cases := []struct {
		name   string
		folder Folder
		entry  rcTransferring
		want   string
	}{
		{"backup is always up", Folder{Mode: ModeBackup}, rcTransferring{SrcFs: "gdrive:"}, "up"},
		{"restore is always down", Folder{Mode: ModeRestore}, rcTransferring{SrcFs: "/home/u"}, "down"},
		{"two-way from local is up", Folder{Mode: ModeTwoWay}, rcTransferring{SrcFs: "/home/u/Docs", DstFs: "gdrive:Docs"}, "up"},
		{"two-way to local is down", Folder{Mode: ModeTwoWay}, rcTransferring{SrcFs: "gdrive:Docs", DstFs: "/home/u/Docs"}, "down"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := transferDirection(tc.folder, tc.entry); got != tc.want {
				t.Fatalf("transferDirection = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestNextDelayBacksOffAndIsFloored(t *testing.T) {
	m := testManager(t)
	folder := Folder{ID: "f1", IntervalSeconds: 60}

	if got := m.nextDelay(folder); got != minInterval {
		t.Fatalf("interval should be floored to %v, got %v", minInterval, got)
	}

	folder.IntervalSeconds = int(minInterval.Seconds())
	m.mu.Lock()
	m.failures[folder.ID] = 2
	m.mu.Unlock()
	if got, want := m.nextDelay(folder), 4*minInterval; got != want {
		t.Fatalf("two failures should quadruple the delay: got %v want %v", got, want)
	}

	m.mu.Lock()
	m.failures[folder.ID] = 50
	m.mu.Unlock()
	if got := m.nextDelay(folder); got != maxBackoff {
		t.Fatalf("backoff should cap at %v, got %v", maxBackoff, got)
	}
}

func TestRescanAndResolveConflicts(t *testing.T) {
	m := testManager(t)
	home, _ := os.UserHomeDir()
	local := filepath.Join(home, "Docs")
	if err := os.MkdirAll(filepath.Join(local, "nested"), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	folder := Folder{ID: "f1", Name: "Docs", Remote: "gdrive", RemotePath: "Docs", LocalPath: local, Mode: ModeTwoWay, ResyncDone: true}
	if err := m.store.putFolder(folder); err != nil {
		t.Fatalf("putFolder: %v", err)
	}

	base := filepath.Join(local, "nested", "notes.txt")
	if err := os.WriteFile(base+suffixLocal, []byte("mine"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	// Only one half present: not resolvable, so not reported.
	m.rescanConflicts(folder)
	if len(m.snapshot().Conflicts) != 0 {
		t.Fatal("a half-written conflict pair must not be reported")
	}

	if err := os.WriteFile(base+suffixCloud, []byte("theirs from the cloud"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	m.rescanConflicts(folder)
	conflicts := m.snapshot().Conflicts
	if len(conflicts) != 1 {
		t.Fatalf("expected one conflict, got %d", len(conflicts))
	}
	c := conflicts[0]
	if c.RelPath != filepath.Join("nested", "notes.txt") {
		t.Fatalf("unexpected conflict path %q", c.RelPath)
	}
	if c.LocalSize != 4 || c.CloudSize != 21 {
		t.Fatalf("conflict sizes wrong: %+v", c)
	}

	if err := m.resolveConflict(c.ID, resolveKeepLocal); err != nil {
		t.Fatalf("resolveConflict: %v", err)
	}
	if data, err := os.ReadFile(base); err != nil || string(data) != "mine" {
		t.Fatalf("keeping the local copy should restore the original name: %v %q", err, data)
	}
	if _, err := os.Stat(base + suffixCloud); !os.IsNotExist(err) {
		t.Fatal("the losing copy should have been moved to the recycle bin")
	}
	// The losing copy is recoverable, not destroyed.
	trashed := filepath.Join(m.store.localTrash(folder.ID), "nested", "notes.txt"+suffixCloud)
	if _, err := os.Stat(trashed); err != nil {
		t.Fatalf("expected the losing copy in the recycle bin: %v", err)
	}
	if len(m.snapshot().Conflicts) != 0 {
		t.Fatal("the conflict should be cleared after resolution")
	}

	if err := m.resolveConflict("nope", resolveKeepLocal); err == nil {
		t.Fatal("resolving an unknown conflict should error")
	}
}

func TestResolveConflictKeepBoth(t *testing.T) {
	m := testManager(t)
	home, _ := os.UserHomeDir()
	local := filepath.Join(home, "Docs")
	if err := os.MkdirAll(local, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	folder := Folder{ID: "f1", Name: "Docs", LocalPath: local, Mode: ModeTwoWay, ResyncDone: true}
	if err := m.store.putFolder(folder); err != nil {
		t.Fatalf("putFolder: %v", err)
	}
	base := filepath.Join(local, "notes.txt")
	os.WriteFile(base+suffixLocal, []byte("a"), 0o600)
	os.WriteFile(base+suffixCloud, []byte("b"), 0o600)
	m.rescanConflicts(folder)

	c := m.snapshot().Conflicts[0]
	if err := m.resolveConflict(c.ID, resolveKeepBoth); err != nil {
		t.Fatalf("resolveConflict: %v", err)
	}
	for _, name := range []string{"notes (this computer).txt", "notes (cloud).txt"} {
		if _, err := os.Stat(filepath.Join(local, name)); err != nil {
			t.Fatalf("expected %q to exist: %v", name, err)
		}
	}

	if err := m.resolveConflict(c.ID, "shred-everything"); err == nil {
		t.Fatal("an unknown resolution should be rejected")
	}
}

func TestRescanConflictsPreservesListOnScanFailure(t *testing.T) {
	m := testManager(t)
	folder := Folder{ID: "f1", Name: "Docs", LocalPath: filepath.Join(os.Getenv("HOME"), "missing"), Mode: ModeTwoWay, ResyncDone: true}
	m.mu.Lock()
	m.conflicts = []Conflict{{ID: "c1", FolderID: folder.ID, RelPath: "kept.txt"}}
	m.mu.Unlock()

	if err := m.rescanConflicts(folder); err == nil {
		t.Fatal("missing local tree should make conflict scan fail")
	}
	state := m.snapshot()
	if len(state.Conflicts) != 1 || state.Conflicts[0].ID != "c1" {
		t.Fatalf("previous conflict list was not preserved: %+v", state.Conflicts)
	}
	m.mu.Lock()
	status := *m.statusLocked(folder.ID)
	m.mu.Unlock()
	if status.State != StateError || !strings.Contains(status.LastError, "conflict scan failed") {
		t.Fatalf("scan failure was not surfaced in folder status with its cause: %+v", status)
	}
}

func TestWatcherDebouncesBurstsIntoOneSync(t *testing.T) {
	previous := watchDebounce
	watchDebounce = 80 * time.Millisecond
	t.Cleanup(func() { watchDebounce = previous })

	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "sub"), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	fired := make(chan string, 8)
	w, err := newWatcher(discardLogger(), func(id string) { fired <- id })
	if err != nil {
		t.Skipf("inotify unavailable in this environment: %v", err)
	}
	t.Cleanup(w.close)

	w.watch("f1", root)
	if watching, reason := w.watchState("f1"); !watching {
		t.Fatalf("expected the tree to be watched, degraded: %q", reason)
	}

	for i := 0; i < 5; i++ {
		path := filepath.Join(root, "sub", "file")
		f, err := os.Create(path + string(rune('a'+i)))
		if err != nil {
			t.Fatalf("create: %v", err)
		}
		f.Close()
	}

	select {
	case id := <-fired:
		if id != "f1" {
			t.Fatalf("unexpected folder id %q", id)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("watcher never reported the change")
	}

	select {
	case <-fired:
		t.Fatal("watcher fired more than once for a single burst")
	case <-time.After(300 * time.Millisecond):
	}

	w.unwatch("f1")
	if watching, _ := w.watchState("f1"); watching {
		t.Fatal("unwatch should clear the folder")
	}
}

func TestWatcherIgnoresInternalPaths(t *testing.T) {
	cases := map[string]bool{
		"/home/u/Docs/report.pdf":              false,
		"/home/u/Docs/.vgs-trash":              true,
		"/home/u/Docs/.vgs-trash/old.txt":      true,
		"/home/u/Docs/report.pdf.partial":      true,
		"/home/u/Docs/.goutputstream-abc":      true,
		"/home/u/Docs/normal.goutputstream-ok": false,
	}
	for path, want := range cases {
		if got := isIgnoredPath(path); got != want {
			t.Fatalf("isIgnoredPath(%q) = %v, want %v", path, got, want)
		}
	}
}

func TestRCClientSendsAuthAndSurfacesErrors(t *testing.T) {
	var gotUser, gotPass, gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotUser, gotPass, _ = r.BasicAuth()
		body, _ := io.ReadAll(r.Body)
		gotBody = string(body)
		switch r.URL.Path {
		case "/core/version":
			json.NewEncoder(w).Encode(rcVersion{Version: "v1.74.4"})
		case "/sync/sync":
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]string{"error": "directory not found"})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	c := newRCClient()
	if c.ready() {
		t.Fatal("a client with no endpoint must not report ready")
	}
	if err := c.callTimeout("core/version", nil, nil, time.Second); err == nil {
		t.Fatal("calling with no endpoint should error")
	}

	c.setEndpoint(srv.URL, "user", "secret")
	var v rcVersion
	if err := c.callTimeout("core/version", map[string]any{"hello": true}, &v, 5*time.Second); err != nil {
		t.Fatalf("core/version: %v", err)
	}
	if v.Version != "v1.74.4" {
		t.Fatalf("unexpected version %q", v.Version)
	}
	if gotUser != "user" || gotPass != "secret" {
		t.Fatalf("basic auth not sent: %q/%q", gotUser, gotPass)
	}
	if !strings.Contains(gotBody, `"hello":true`) {
		t.Fatalf("params not sent: %q", gotBody)
	}

	err := c.callTimeout("sync/sync", nil, nil, 5*time.Second)
	if err == nil || err.Error() != "directory not found" {
		t.Fatalf("expected rclone's own message, got %v", err)
	}
}

func TestParseRCTimeAndFirstLine(t *testing.T) {
	if got := parseRCTime("2026-07-30T10:11:12.5Z"); got != time.Date(2026, 7, 30, 10, 11, 12, 0, time.UTC).Unix() {
		t.Fatalf("parseRCTime = %d", got)
	}
	if parseRCTime("") != 0 || parseRCTime("not a time") != 0 {
		t.Fatal("unparseable timestamps should be zero")
	}
	if got := firstLine("  boom\nstack trace\n"); got != "boom" {
		t.Fatalf("firstLine = %q", got)
	}
	if firstLine("   ") != "" {
		t.Fatal("blank input should stay blank")
	}
}

func TestSanitizeDirName(t *testing.T) {
	cases := map[string]string{
		"My Drive":     "My Drive",
		"a/b:c":        "a-b-c",
		"":             "cloud",
		"...":          "cloud",
		"../../escape": "escape",
	}
	for in, want := range cases {
		if got := sanitizeDirName(in); got != want {
			t.Fatalf("sanitizeDirName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSnapshotReflectsPauseAndResyncState(t *testing.T) {
	m := testManager(t)
	home, _ := os.UserHomeDir()
	local := filepath.Join(home, "Docs")
	os.MkdirAll(local, 0o700)

	pending := Folder{ID: "f1", Name: "Pending", LocalPath: local, Remote: "gdrive", Mode: ModeTwoWay}
	paused := Folder{ID: "f2", Name: "Paused", LocalPath: filepath.Join(home, "Other"), Remote: "gdrive", Mode: ModeBackup, Paused: true, ResyncDone: true}
	m.store.putFolder(pending)
	m.store.putFolder(paused)

	byID := map[string]FolderStatus{}
	for _, st := range m.snapshot().Statuses {
		byID[st.ID] = st
	}
	if byID["f1"].State != StateNeedsResync {
		t.Fatalf("a two-way folder without a baseline should ask for one, got %q", byID["f1"].State)
	}
	if byID["f2"].State != StatePaused {
		t.Fatalf("a paused folder should report paused, got %q", byID["f2"].State)
	}
}

func TestStartSyncRefusesWithoutBaseline(t *testing.T) {
	m := testManager(t)
	home, _ := os.UserHomeDir()
	local := filepath.Join(home, "Docs")
	os.MkdirAll(local, 0o700)
	m.store.putFolder(Folder{ID: "f1", LocalPath: local, Remote: "gdrive", Mode: ModeTwoWay})

	err := m.startSync("f1", syncOptions{Trigger: triggerManual})
	if err == nil || !strings.Contains(err.Error(), "baseline") {
		t.Fatalf("expected a baseline requirement, got %v", err)
	}

	m.store.putFolder(Folder{ID: "f2", LocalPath: local, Remote: "gdrive", Mode: ModeStream})
	if err := m.startSync("f2", syncOptions{Trigger: triggerManual}); err == nil {
		t.Fatal("streamed folders do not run syncs")
	}
	if err := m.startSync("missing", syncOptions{Trigger: triggerManual}); err == nil {
		t.Fatal("expected an error for an unknown folder")
	}
}

func TestPruneTrashRemovesExpiredEntries(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	st, err := newStore()
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	dir := filepath.Join(st.localTrash("f1"), "nested")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	old := filepath.Join(dir, "old.txt")
	fresh := filepath.Join(dir, "fresh.txt")
	os.WriteFile(old, []byte("x"), 0o600)
	os.WriteFile(fresh, []byte("x"), 0o600)

	stale := time.Now().Add(-72 * time.Hour)
	if err := os.Chtimes(old, stale, stale); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	st.pruneTrash(time.Now().Add(-24 * time.Hour).Unix())

	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("expired trash should be removed")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Fatalf("recent trash must be kept: %v", err)
	}
}

func TestHumanizeOptionName(t *testing.T) {
	cases := map[string]string{
		"client_id":      "Client ID",
		"client_secret":  "Client Secret",
		"root_folder_id": "Root Folder ID",
		"scope":          "Scope",
		"aws_sso_url":    "AWS SSO URL",
		"sha1":           "SHA1",
		"":               "",
	}
	for in, want := range cases {
		if got := humanizeOptionName(in); got != want {
			t.Fatalf("humanizeOptionName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestShortProviderName(t *testing.T) {
	cases := []struct {
		name, description, want string
	}{
		{"drive", "Google Drive", "Google Drive"},
		{"dropbox", "Dropbox", "Dropbox"},
		{
			"s3",
			"Amazon S3 Compliant Storage Providers including AWS, Alibaba, Ceph, China Mobile, Cloudflare, ArvanCloud, Digital Ocean, Dreamhost, Huawei OBS, IBM COS, Lyve Cloud, Minio, Netease, RackCorp, Scaleway, SeaweedFS, StackPath, Storj, Tencent COS, Qiniu and Wasabi",
			"Amazon S3 Compliant Storage Providers",
		},
		{"gcs", "Google Cloud Storage (this is not Google Drive)", "Google Cloud Storage"},
		{"weird", "", "weird"},
		{"long", strings.Repeat("x", 80), strings.Repeat("x", 47) + "…"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := shortProviderName(tc.name, tc.description); got != tc.want {
				t.Fatalf("shortProviderName(%q) = %q, want %q", tc.name, got, tc.want)
			}
		})
	}
}

func TestMoveFileFallsBackAcrossFilesystems(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src.txt")
	dst := filepath.Join(dir, "sub", "dst.txt")
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(src, []byte("payload"), 0o640); err != nil {
		t.Fatalf("write: %v", err)
	}

	if err := moveFile(src, dst); err != nil {
		t.Fatalf("moveFile: %v", err)
	}
	data, err := os.ReadFile(dst)
	if err != nil || string(data) != "payload" {
		t.Fatalf("destination wrong: %v %q", err, data)
	}
	if _, err := os.Stat(src); !os.IsNotExist(err) {
		t.Fatal("source should be gone after a move")
	}

	if err := moveFile(filepath.Join(dir, "missing"), dst); err == nil {
		t.Fatal("expected an error moving a missing file")
	}
}

func TestValidateRemoteName(t *testing.T) {
	for _, name := range []string{"gdrive", "my-drive", "work.drive", "a_b"} {
		if err := validateRemoteName(name); err != nil {
			t.Fatalf("%q should be valid: %v", name, err)
		}
	}
	for _, name := range []string{"", "has space", "semi;colon", "slash/es", strings.Repeat("x", 41)} {
		if err := validateRemoteName(name); err == nil {
			t.Fatalf("%q should be rejected", name)
		}
	}
}

func TestDecodeStringMap(t *testing.T) {
	got := decodeStringMap(json.RawMessage(`{"user":"me","port":22,"secure":true,"skip":[1,2]}`))
	want := map[string]string{"user": "me", "port": "22", "secure": "true"}
	if len(got) != len(want) {
		t.Fatalf("decodeStringMap = %+v, want %+v", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Fatalf("decodeStringMap[%q] = %q, want %q", k, got[k], v)
		}
	}
	if len(decodeStringMap(nil)) != 0 {
		t.Fatal("nil params should decode to an empty map")
	}
}

// fakeRC wires a Manager's rc client to an httptest server whose routes are
// given as path -> handler. Anything unrouted answers 404, which the client
// surfaces as an error — so a test that forgets a route fails loudly instead of
// silently succeeding.
func fakeRC(t *testing.T, m *Manager, routes map[string]http.HandlerFunc) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if handler, ok := routes[strings.TrimPrefix(r.URL.Path, "/")]; ok {
			handler(w, r)
			return
		}
		w.WriteHeader(http.StatusNotFound)
		json.NewEncoder(w).Encode(map[string]string{"error": "no such route: " + r.URL.Path})
	}))
	t.Cleanup(srv.Close)
	m.client.setEndpoint(srv.URL, "user", "pass")
	return srv
}

func jsonRoute(value any) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(value)
	}
}

func errorRoute(message string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": message})
	}
}

func TestRefreshAccountsResolvesIdentityAndOAuth(t *testing.T) {
	m := testManager(t)
	if err := m.store.putAccountMeta("gdrive", AccountMeta{Label: "Work Drive"}); err != nil {
		t.Fatalf("putAccountMeta: %v", err)
	}
	if err := m.store.putFolder(Folder{ID: "f1", Remote: "gdrive", LocalPath: "/tmp/a", Mode: ModeBackup}); err != nil {
		t.Fatalf("putFolder: %v", err)
	}

	fakeRC(t, m, map[string]http.HandlerFunc{
		"config/listremotes": jsonRoute(rcListRemotes{Remotes: []string{"gdrive:", "scratch"}}),
		"config/get": func(w http.ResponseWriter, r *http.Request) {
			body, _ := io.ReadAll(r.Body)
			if strings.Contains(string(body), "gdrive") {
				json.NewEncoder(w).Encode(map[string]string{"type": "drive", "token": "{}", "client_id": "abc123"})
				return
			}
			json.NewEncoder(w).Encode(map[string]string{"type": "local"})
		},
		"config/providers": jsonRoute(map[string]any{"providers": []map[string]any{
			{"Name": "drive", "Description": "Google Drive", "Options": []map[string]any{{"Name": "token"}}},
		}}),
		// Health/quota run in a goroutine; route them so the sweep cannot 404.
		"operations/about": jsonRoute(map[string]any{}),
	})

	m.refreshAccounts()

	m.mu.Lock()
	accounts := append([]Account{}, m.accounts...)
	m.mu.Unlock()

	// The "scratch" remote is type local, a wrapper backend that is not a
	// cloud account and must not be listed.
	if len(accounts) != 1 {
		t.Fatalf("expected one visible account, got %+v", accounts)
	}
	got := accounts[0]
	if got.Name != "gdrive" {
		t.Fatalf("name = %q", got.Name)
	}
	if got.Provider != "Google Drive" {
		t.Fatalf("provider = %q, want the display name", got.Provider)
	}
	if got.Label != "Work Drive" {
		t.Fatalf("label = %q, want the stored label", got.Label)
	}
	if !got.OAuth {
		t.Fatal("a remote with a stored token must be reconnectable")
	}
	if got.ClientID != "abc123" {
		t.Fatalf("clientId = %q", got.ClientID)
	}
	if got.Folders != 1 {
		t.Fatalf("folders = %d, want 1", got.Folders)
	}
	if got.DisplayName() != "Work Drive" {
		t.Fatalf("DisplayName = %q", got.DisplayName())
	}
}

func TestAccountDisplayNameFallsBack(t *testing.T) {
	if got := (Account{Name: "gdrive", Provider: "Google Drive"}).DisplayName(); got != "Google Drive" {
		t.Fatalf("DisplayName = %q, want the provider", got)
	}
	if got := (Account{Name: "gdrive"}).DisplayName(); got != "gdrive" {
		t.Fatalf("DisplayName = %q, want the remote name", got)
	}
}

// checkAccount must not fall back to a full root listing when the backend can
// answer about: listing the root of a large account routinely outruns any
// sensible timeout, which would report a healthy account as broken.
func TestCheckAccountUsesAboutAndSkipsListing(t *testing.T) {
	m := testManager(t)
	m.accounts = []Account{{Name: "gdrive", Health: HealthUnknown}}

	total, used, free := int64(100), int64(40), int64(60)
	listed := false
	fakeRC(t, m, map[string]http.HandlerFunc{
		"operations/about": jsonRoute(rcAbout{Total: &total, Used: &used, Free: &free}),
		"operations/list": func(w http.ResponseWriter, r *http.Request) {
			listed = true
			json.NewEncoder(w).Encode(rcList{})
		},
	})

	if err := m.checkAccount("gdrive"); err != nil {
		t.Fatalf("checkAccount: %v", err)
	}
	if listed {
		t.Fatal("about answered, so the expensive listing must not run")
	}
	m.mu.Lock()
	got := m.accounts[0]
	m.mu.Unlock()
	if got.Health != HealthOK {
		t.Fatalf("health = %q, want ok", got.Health)
	}
	if got.CheckedUnix == 0 {
		t.Fatal("a completed check must stamp the time")
	}
	if got.Quota == nil || got.Quota.Used == nil || *got.Quota.Used != 40 {
		t.Fatalf("quota not recorded: %+v", got.Quota)
	}
}

func TestCheckAccountFallsBackToListingThenReportsFailure(t *testing.T) {
	m := testManager(t)
	m.accounts = []Account{{Name: "dav", Health: HealthUnknown}}

	listed := false
	fakeRC(t, m, map[string]http.HandlerFunc{
		"operations/about": errorRoute("command not found"),
		"operations/list": func(w http.ResponseWriter, r *http.Request) {
			listed = true
			json.NewEncoder(w).Encode(rcList{})
		},
	})
	if err := m.checkAccount("dav"); err != nil {
		t.Fatalf("checkAccount: %v", err)
	}
	if !listed {
		t.Fatal("about failed, so the listing fallback must run")
	}
	m.mu.Lock()
	health := m.accounts[0].Health
	m.mu.Unlock()
	if health != HealthOK {
		t.Fatalf("health = %q, want ok when the listing succeeds", health)
	}

	fakeRC(t, m, map[string]http.HandlerFunc{
		"operations/about": errorRoute("command not found"),
		"operations/list":  errorRoute("no such host"),
	})
	if err := m.checkAccount("dav"); err == nil {
		t.Fatal("an unreachable account must report an error")
	}
	m.mu.Lock()
	got := m.accounts[0]
	m.mu.Unlock()
	if got.Health != HealthError {
		t.Fatalf("health = %q, want error", got.Health)
	}
	if got.Error != "no such host" {
		t.Fatalf("error = %q, want rclone's own message", got.Error)
	}
}

// Account removal requires acknowledgement of dependent folder removal because
// those folders need its credentials to run.
func TestRemoveRemoteRefusesToStrandFoldersThenRemovesThem(t *testing.T) {
	m := testManager(t)
	if err := m.store.putFolder(Folder{ID: "f1", Remote: "gdrive", LocalPath: "/tmp/a", Mode: ModeBackup}); err != nil {
		t.Fatalf("putFolder: %v", err)
	}
	if err := m.store.putFolder(Folder{ID: "f2", Remote: "other", LocalPath: "/tmp/b", Mode: ModeBackup}); err != nil {
		t.Fatalf("putFolder: %v", err)
	}
	if err := m.store.putAccountMeta("gdrive", AccountMeta{Label: "Work"}); err != nil {
		t.Fatalf("putAccountMeta: %v", err)
	}
	m.statuses["f1"] = &FolderStatus{ID: "f1"}
	m.conflicts = []Conflict{{ID: "c1", FolderID: "f1"}, {ID: "c2", FolderID: "f2"}}

	deleted := false
	fakeRC(t, m, map[string]http.HandlerFunc{
		"config/delete": func(w http.ResponseWriter, r *http.Request) {
			deleted = true
			json.NewEncoder(w).Encode(map[string]any{})
		},
		"config/listremotes": jsonRoute(rcListRemotes{}),
	})

	if err := m.removeRemote("gdrive", false); err == nil {
		t.Fatal("disconnecting an account with folders must be refused")
	}
	if deleted {
		t.Fatal("a refused disconnect must not delete the rclone remote")
	}
	if _, ok := m.store.folder("f1"); !ok {
		t.Fatal("a refused disconnect must not touch folders")
	}

	if err := m.removeRemote("gdrive", true); err != nil {
		t.Fatalf("confirmed removeRemote: %v", err)
	}
	if !deleted {
		t.Fatal("a confirmed disconnect must delete the rclone remote")
	}
	if _, ok := m.store.folder("f1"); ok {
		t.Fatal("the account's folder should be gone")
	}
	if _, ok := m.store.folder("f2"); !ok {
		t.Fatal("another account's folder must survive")
	}
	if _, ok := m.statuses["f1"]; ok {
		t.Fatal("removed folder left runtime status behind")
	}
	if len(m.conflicts) != 1 || m.conflicts[0].ID != "c2" {
		t.Fatalf("conflicts not pruned to the surviving folder: %+v", m.conflicts)
	}
	if m.store.accountMeta("gdrive").Label != "" {
		t.Fatal("the account label should be cleared with the account")
	}
}

func TestSetAccountLabelValidatesAndPersists(t *testing.T) {
	m := testManager(t)
	m.accounts = []Account{{Name: "gdrive"}}

	if err := m.setAccountLabel("nope", "x"); err == nil {
		t.Fatal("labelling an unknown account must fail")
	}
	if err := m.setAccountLabel("gdrive", strings.Repeat("x", 61)); err == nil {
		t.Fatal("an over-long label must be rejected")
	}
	if err := m.setAccountLabel("gdrive", "  Work Drive  "); err != nil {
		t.Fatalf("setAccountLabel: %v", err)
	}
	if got := m.store.accountMeta("gdrive").Label; got != "Work Drive" {
		t.Fatalf("stored label = %q", got)
	}
	m.mu.Lock()
	inState := m.accounts[0].Label
	m.mu.Unlock()
	if inState != "Work Drive" {
		t.Fatalf("state label = %q", inState)
	}

	if err := m.setAccountLabel("gdrive", ""); err != nil {
		t.Fatalf("clear label: %v", err)
	}
	if got := m.store.accountMeta("gdrive").Label; got != "" {
		t.Fatalf("label should be cleared, got %q", got)
	}
}

func TestReconnectRemoteRejectsUnknownAndNonOAuthAccounts(t *testing.T) {
	m := testManager(t)
	m.accounts = []Account{{Name: "dav", Type: "webdav"}}
	m.providers = map[string]providerDetails{"webdav": {name: "WebDAV"}}
	m.providersLoaded = true

	if err := m.reconnectRemote("nope", nil); err == nil {
		t.Fatal("reconnecting an unknown account must fail")
	}
	if err := m.reconnectRemote("dav", nil); err == nil {
		t.Fatal("a credentials-based account has no browser sign-in to repeat")
	}
	m.mu.Lock()
	active := m.oauth.Active
	m.mu.Unlock()
	if active {
		t.Fatal("a rejected reconnect must not leave a sign-in marked in progress")
	}
}

func TestAccountMetaSurvivesReload(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	st, err := newStore()
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	if err := st.putAccountMeta("gdrive", AccountMeta{Label: "Work"}); err != nil {
		t.Fatalf("putAccountMeta: %v", err)
	}
	reloaded, err := newStore()
	if err != nil {
		t.Fatalf("newStore(reload): %v", err)
	}
	if got := reloaded.accountMeta("gdrive").Label; got != "Work" {
		t.Fatalf("label did not round-trip: %q", got)
	}
	if got := reloaded.foldersForRemote("gdrive"); len(got) != 0 {
		t.Fatalf("foldersForRemote on an empty store = %+v", got)
	}
}

// The carry-over must preserve what a refresh cannot re-derive, and must not
// resurrect a transient "checking" or describe a remote that was replaced.
func TestCarryOverAccounts(t *testing.T) {
	previous := map[string]Account{
		"gdrive":  {Name: "gdrive", Type: "drive", Provider: "Google Drive", User: "me@x", ClientID: "cid", OAuth: true, Health: HealthOK, CheckedUnix: 99, Error: ""},
		"stale":   {Name: "stale", Type: "drive", Health: HealthChecking, CheckedUnix: 50},
		"swapped": {Name: "swapped", Type: "drive", Health: HealthOK, CheckedUnix: 77, Error: "old"},
		"slow":    {Name: "slow", Type: "dropbox", Provider: "Dropbox", User: "you@x", ClientID: "cid2", OAuth: true, Health: HealthOK, CheckedUnix: 88},
	}
	fresh := []Account{
		{Name: "gdrive", Type: "drive", Provider: "Google Drive", Health: HealthUnknown},
		{Name: "stale", Type: "drive", Health: HealthUnknown},
		{Name: "swapped", Type: "webdav", Health: HealthUnknown},
		{Name: "slow", Health: HealthUnknown},
		{Name: "brandnew", Type: "b2", Health: HealthUnknown},
	}

	carryOverAccounts(fresh, previous, map[string]bool{"slow": true})

	if fresh[0].Health != HealthOK || fresh[0].CheckedUnix != 99 {
		t.Fatalf("known-good account lost its health: %+v", fresh[0])
	}
	if fresh[1].Health != HealthUnknown {
		t.Fatalf("a transient 'checking' was carried forward: %q", fresh[1].Health)
	}
	if fresh[2].Health != HealthUnknown || fresh[2].Error != "" || fresh[2].CheckedUnix != 0 {
		t.Fatalf("a replaced remote inherited the old one's state: %+v", fresh[2])
	}
	// config/get failed for "slow": its identity must survive rather than
	// render as a nameless account with no repair path.
	if fresh[3].Type != "dropbox" || fresh[3].Provider != "Dropbox" || fresh[3].User != "you@x" || !fresh[3].OAuth || fresh[3].ClientID != "cid2" {
		t.Fatalf("unreadable account was blanked: %+v", fresh[3])
	}
	if fresh[4].Health != HealthUnknown || fresh[4].Quota != nil {
		t.Fatalf("a new account picked up state from nowhere: %+v", fresh[4])
	}
}

// Account refresh and health updates share state and must remain safe when run
// concurrently.
func TestRefreshAccountsRacesHealthCheckCleanly(t *testing.T) {
	m := testManager(t)
	fakeRC(t, m, map[string]http.HandlerFunc{
		"config/listremotes": jsonRoute(rcListRemotes{Remotes: []string{"gdrive"}}),
		"config/get":         jsonRoute(map[string]string{"type": "drive"}),
		"config/providers":   jsonRoute(map[string]any{"providers": []map[string]any{}}),
		"operations/about":   jsonRoute(map[string]any{}),
	})
	m.accounts = []Account{{Name: "gdrive", Type: "drive", Health: HealthUnknown}}

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(2)
		go func() { defer wg.Done(); m.refreshAccounts() }()
		go func() { defer wg.Done(); _ = m.checkAccount("gdrive") }()
	}
	wg.Wait()
}

func TestPruneAccountMetaDropsRemotesThatNoLongerExist(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	st, err := newStore()
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	for _, name := range []string{"gdrive", "gone"} {
		if err := st.putAccountMeta(name, AccountMeta{Label: "L-" + name}); err != nil {
			t.Fatalf("putAccountMeta: %v", err)
		}
	}
	if err := st.pruneAccountMeta(map[string]bool{"gdrive": true}); err != nil {
		t.Fatalf("pruneAccountMeta: %v", err)
	}
	if st.accountMeta("gone").Label != "" {
		t.Fatal("a label for a deleted remote survived; a new account reusing the name would inherit it")
	}
	if st.accountMeta("gdrive").Label != "L-gdrive" {
		t.Fatal("a live account lost its label")
	}
}

// Folders are replayed from disk and scheduled automatically, so a remote that
// is not a plain account name must never survive a load.
func TestStoreRejectsInlineRemoteConnectionStrings(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgDir := filepath.Join(home, ".config", "vshell")
	if err := os.MkdirAll(cfgDir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	goodLocal := filepath.Join(home, "good")
	evilLocal := filepath.Join(home, "evil")
	if err := os.MkdirAll(goodLocal, 0o700); err != nil {
		t.Fatalf("mkdir good: %v", err)
	}
	if err := os.MkdirAll(evilLocal, 0o700); err != nil {
		t.Fatalf("mkdir evil: %v", err)
	}
	raw, err := json.Marshal(configFile{Version: 1, Folders: []Folder{
		{ID: "good", Remote: "gdrive", LocalPath: goodLocal, Mode: ModeBackup},
		{ID: "evil", Remote: ":sftp,host=attacker.example,user=x:", LocalPath: evilLocal, Mode: ModeBackup},
	}})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(filepath.Join(cfgDir, "cloudsync.json"), raw, 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	st, err := newStore()
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	if _, ok := st.folder("evil"); ok {
		t.Fatal("an inline rclone connection string was loaded and would be synced automatically")
	}
	if _, ok := st.folder("good"); !ok {
		t.Fatal("a legitimate folder was dropped")
	}
	if len(st.rejected) != 1 {
		t.Fatalf("rejection not recorded for the operator: %+v", st.rejected)
	}
	if len(st.snapshotWarnings()) == 0 {
		t.Fatal("rejected persisted folders should be surfaced as warnings")
	}
}

func TestStoreRejectsUnsafePersistedFolders(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgDir := filepath.Join(home, ".config", "vshell")
	if err := os.MkdirAll(cfgDir, 0o700); err != nil {
		t.Fatalf("mkdir config: %v", err)
	}
	goodLocal := filepath.Join(home, "Docs")
	if err := os.MkdirAll(goodLocal, 0o700); err != nil {
		t.Fatalf("mkdir docs: %v", err)
	}
	raw, err := json.Marshal(configFile{
		Version:  1,
		Settings: Settings{MountRoot: "/tmp/not-vgs"},
		Folders: []Folder{
			{ID: "good", Remote: "gdrive", RemotePath: "Docs", LocalPath: goodLocal, Mode: ModeBackup},
			{ID: "home", Remote: "gdrive", RemotePath: "Home", LocalPath: home, Mode: ModeBackup},
			{ID: "../escape", Remote: "gdrive", RemotePath: "Escape", LocalPath: goodLocal, Mode: ModeBackup},
			{ID: "stream", Name: "../../shadow", Remote: "gdrive", RemotePath: "Stream", LocalPath: "/tmp/evil", Mode: ModeStream},
		},
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(filepath.Join(cfgDir, "cloudsync.json"), raw, 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}

	st, err := newStore()
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	if _, ok := st.folder("good"); !ok {
		t.Fatal("safe persisted folder was dropped")
	}
	if _, ok := st.folder("home"); ok {
		t.Fatal("home-directory sync survived load validation")
	}
	if _, ok := st.folder("../escape"); ok {
		t.Fatal("path-traversal folder id survived load validation")
	}
	stream, ok := st.folder("stream")
	if !ok {
		t.Fatal("safe stream folder should survive with a sanitized mount path")
	}
	if !strings.HasPrefix(stream.LocalPath, filepath.Join(home, "CloudSync")+string(os.PathSeparator)) {
		t.Fatalf("stream mount escaped the default mount root: %q", stream.LocalPath)
	}
	if st.snapshotSettings().MountRoot != "" {
		t.Fatalf("unsafe mount root was not cleared: %q", st.snapshotSettings().MountRoot)
	}
	if len(st.rejected) != 2 {
		t.Fatalf("expected two rejected folders, got %+v", st.rejected)
	}
	if len(st.snapshotWarnings()) < 3 {
		t.Fatalf("expected mount-root and folder warnings, got %+v", st.snapshotWarnings())
	}
}

func TestStoreBacksUpSuspectConfigBeforeRewrite(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgDir := filepath.Join(home, ".config", "vshell")
	if err := os.MkdirAll(cfgDir, 0o700); err != nil {
		t.Fatalf("mkdir config: %v", err)
	}
	configPath := filepath.Join(cfgDir, "cloudsync.json")
	if err := os.WriteFile(configPath, []byte("{not json"), 0o600); err != nil {
		t.Fatalf("write corrupt config: %v", err)
	}
	st, err := newStore()
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	settings := st.snapshotSettings()
	settings.BandwidthUp = "1M"
	if err := st.putSettings(settings); err != nil {
		t.Fatalf("putSettings should back up before rewriting: %v", err)
	}
	matches, err := filepath.Glob(configPath + ".invalid.*")
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	if len(matches) != 1 {
		t.Fatalf("expected one backup of the suspect config, got %+v", matches)
	}
	backup, err := os.ReadFile(matches[0])
	if err != nil {
		t.Fatalf("read backup: %v", err)
	}
	if string(backup) != "{not json" {
		t.Fatalf("backup did not preserve original config: %q", backup)
	}
}

func TestStoreBacksUpSuspectHistoryBeforeWriting(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	stateDir := filepath.Join(home, ".local", "state", "vshell", "cloudsync")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatalf("mkdir state: %v", err)
	}
	historyPath := filepath.Join(stateDir, "history.json")
	if err := os.WriteFile(historyPath, []byte("{not json"), 0o600); err != nil {
		t.Fatalf("write corrupt history: %v", err)
	}

	st, err := newStore()
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	st.appendHistory(HistoryEntry{ID: "run-1", FolderID: "f1"})
	matches, err := filepath.Glob(historyPath + ".invalid.*")
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	if len(matches) != 1 {
		t.Fatalf("expected one backup of suspect history, got %+v", matches)
	}
	backup, err := os.ReadFile(matches[0])
	if err != nil {
		t.Fatalf("read history backup: %v", err)
	}
	if string(backup) != "{not json" {
		t.Fatalf("history backup did not preserve original: %q", backup)
	}
}

func TestStoreRejectsPersistedRemotePathTraversal(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgDir := filepath.Join(home, ".config", "vshell")
	local := filepath.Join(home, "Docs")
	if err := os.MkdirAll(local, 0o700); err != nil {
		t.Fatalf("mkdir docs: %v", err)
	}
	if err := os.MkdirAll(cfgDir, 0o700); err != nil {
		t.Fatalf("mkdir config: %v", err)
	}
	raw := `{"version":1,"folders":[{"id":"escaped","remote":"gdrive","remotePath":"Docs/../Private","localPath":"` + local + `","mode":"backup"}]}`
	if err := os.WriteFile(filepath.Join(cfgDir, "cloudsync.json"), []byte(raw), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	st, err := newStore()
	if err != nil {
		t.Fatalf("newStore: %v", err)
	}
	if _, ok := st.folder("escaped"); ok {
		t.Fatal("a persisted remote traversal path was activated")
	}
	if len(st.snapshotWarnings()) == 0 {
		t.Fatal("rejected remote traversal should be visible to the user")
	}
}

func TestNormalizeFolderRejectsInlineRemote(t *testing.T) {
	m := testManager(t)
	_, err := m.normalizeFolder(Folder{Remote: ":sftp,host=attacker.example:", LocalPath: t.TempDir(), Mode: ModeBackup})
	if err == nil {
		t.Fatal("addFolder must not accept an on-the-fly rclone backend as an account")
	}
}

func TestBackendEnvPrefix(t *testing.T) {
	// rclone authorize needs the backend-specific client credential prefix to match
	// the credentials written to the account config.
	for in, want := range map[string]string{
		"drive":              "RCLONE_DRIVE_",
		"googlecloudstorage": "RCLONE_GOOGLECLOUDSTORAGE_",
		"my-backend":         "RCLONE_MY_BACKEND_",
	} {
		if got := backendEnvPrefix(in); got != want {
			t.Fatalf("backendEnvPrefix(%q) = %q, want %q", in, got, want)
		}
	}
}

// A timer that had already fired when Close stopped it must not launch a sync
// that nothing will ever poll or cancel.
func TestStartSyncRefusesDuringShutdown(t *testing.T) {
	m := testManager(t)
	local := t.TempDir()
	folder, err := m.normalizeFolder(Folder{ID: "f1", Remote: "gdrive", LocalPath: local, Mode: ModeBackup})
	if err != nil {
		t.Fatalf("normalizeFolder: %v", err)
	}
	if err := m.store.putFolder(folder); err != nil {
		t.Fatalf("putFolder: %v", err)
	}

	m.mu.Lock()
	m.closed = true
	m.mu.Unlock()

	if err := m.startSync(folder.ID, syncOptions{Trigger: triggerStartup}); err == nil {
		t.Fatal("a sync must not start while the service is shutting down")
	}
	m.mu.Lock()
	jobs := len(m.jobs)
	m.mu.Unlock()
	if jobs != 0 {
		t.Fatalf("a job was recorded during shutdown: %d", jobs)
	}
}

// finishJob must reclaim runtime state when the folder is absent from
// configuration.
func TestFinishJobDropsStateForRemovedFolder(t *testing.T) {
	m := testManager(t)
	m.statuses["gone"] = &FolderStatus{ID: "gone", State: StateSyncing}
	m.failures["gone"] = 3
	m.jobs["gone"] = &activeJob{FolderID: "gone"}

	m.finishJob(m.jobs["gone"], false, "folder was removed", rcStats{})

	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.statuses["gone"]; ok {
		t.Fatal("status for a removed folder was resurrected")
	}
	if _, ok := m.failures["gone"]; ok {
		t.Fatal("failure counter for a removed folder survived")
	}
	if _, ok := m.jobs["gone"]; ok {
		t.Fatal("job for a removed folder survived")
	}
}

// Unreadable job status must end the run as interrupted so the folder does not
// remain stuck on Syncing.
func TestPollJobGivesUpAfterRepeatedStatusFailures(t *testing.T) {
	m := testManager(t)
	local := t.TempDir()
	folder, err := m.normalizeFolder(Folder{ID: "f1", Remote: "gdrive", LocalPath: local, Mode: ModeBackup})
	if err != nil {
		t.Fatalf("normalizeFolder: %v", err)
	}
	if err := m.store.putFolder(folder); err != nil {
		t.Fatalf("putFolder: %v", err)
	}
	fakeRC(t, m, map[string]http.HandlerFunc{
		"core/stats": jsonRoute(rcStats{}),
		"job/status": errorRoute("job not found"),
	})

	job := &activeJob{FolderID: folder.ID, RCJobID: 7, Group: statsGroup(folder.ID)}
	m.mu.Lock()
	m.jobs[folder.ID] = job
	m.statusLocked(folder.ID).State = StateSyncing
	m.mu.Unlock()

	for i := 0; i < statusPollLimit; i++ {
		m.pollJob(job)
	}

	m.mu.Lock()
	_, stillRunning := m.jobs[folder.ID]
	state := m.statuses[folder.ID].State
	m.mu.Unlock()
	if stillRunning {
		t.Fatal("the job was never finished, so the folder stays 'Syncing' forever")
	}
	if state != StateError {
		t.Fatalf("state = %q, want an actionable error state", state)
	}
}

// Keep-both must not leave one copy renamed and the pair dropped from the
// Conflicts view when the second rename fails.
func TestResolveKeepBothUndoesAPartialRename(t *testing.T) {
	m := testManager(t)
	local := t.TempDir()
	folder, err := m.normalizeFolder(Folder{ID: "f1", Remote: "gdrive", LocalPath: local, Mode: ModeTwoWay})
	if err != nil {
		t.Fatalf("normalizeFolder: %v", err)
	}
	folder.ResyncDone = true
	if err := m.store.putFolder(folder); err != nil {
		t.Fatalf("putFolder: %v", err)
	}

	localCopy := filepath.Join(local, "notes.txt"+suffixLocal)
	if err := os.WriteFile(localCopy, []byte("mine"), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	cloudCopy := filepath.Join(local, "notes.txt"+suffixCloud)

	m.mu.Lock()
	m.conflicts = []Conflict{{ID: "c1", FolderID: folder.ID, RelPath: "notes.txt", LocalPath: localCopy, CloudPath: cloudCopy}}
	m.mu.Unlock()

	if err := m.resolveConflict("c1", resolveKeepBoth); err == nil {
		t.Fatal("keep-both should report the failed rename")
	}
	if _, err := os.Stat(localCopy); err != nil {
		t.Fatalf("the first rename was not undone, so the conflict pair is now broken: %v", err)
	}
	entries, err := os.ReadDir(local)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	if len(entries) != 1 {
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Fatalf("an orphan file was left in the synced tree: %v", names)
	}
}

// Watcher failure must reach folder state so the UI reports that real-time sync
// is unavailable.
func TestWatcherDegradeNotifiesAndRecordsReason(t *testing.T) {
	w, err := newWatcher(discardLogger(), nil)
	if err != nil {
		t.Skipf("inotify unavailable: %v", err)
	}
	defer w.close()

	root := t.TempDir()
	w.watch("f1", root)
	notified := make(chan struct{}, 4)
	w.onDegraded = func() { notified <- struct{}{} }

	w.degrade("", "watching stopped")

	select {
	case <-notified:
	case <-time.After(2 * time.Second):
		t.Fatal("degradation never notified the manager, so it never reaches the UI")
	}
	watching, reason := w.watchState("f1")
	if watching {
		t.Fatal("a folder whose watches died must not report as watched")
	}
	if reason != "watching stopped" {
		t.Fatalf("reason = %q", reason)
	}
	// Repeating the same reason must not re-notify, or a dying loop would spin.
	w.degrade("", "watching stopped")
	select {
	case <-notified:
		t.Fatal("an unchanged reason should not notify again")
	case <-time.After(200 * time.Millisecond):
	}
}

func TestValidateSettingsClampsAndConfinesMountRoot(t *testing.T) {
	// testManager sets its own throwaway HOME, so the mount root has to be
	// derived from that one rather than a separate temp dir.
	m := testManager(t)
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatalf("UserHomeDir: %v", err)
	}

	s := Settings{Transfers: 10000, Checkers: 10000, TrashRetentionDays: 999999, MountRoot: filepath.Join(home, "CloudSync")}
	if err := m.validateSettings(&s); err != nil {
		t.Fatalf("validateSettings: %v", err)
	}
	if s.Transfers != maxConcurrency || s.Checkers != maxConcurrency {
		t.Fatalf("concurrency not clamped: %+v", s)
	}
	if s.TrashRetentionDays > 3650 {
		t.Fatalf("retention not clamped: %d", s.TrashRetentionDays)
	}

	// A mount root outside $HOME would put FUSE mounts anywhere the user can
	// write, including over a directory something else depends on.
	outside := Settings{MountRoot: "/tmp/anywhere"}
	if err := m.validateSettings(&outside); err == nil {
		t.Fatal("a mount root outside the home directory must be refused")
	}
	relative := Settings{MountRoot: "not/absolute"}
	if err := m.validateSettings(&relative); err == nil {
		t.Fatal("a relative mount root must be refused")
	}
}

func TestBrowseRejectsTraversal(t *testing.T) {
	m := testManager(t)
	if _, err := m.browse("gdrive", "docs/../../etc"); err == nil {
		t.Fatal("a traversal segment must be refused before it reaches rclone")
	}
}

// A stream whose FUSE mount cannot be torn down keeps its persisted state:
// pausing it, removing it, or pausing everything fails, returns no result, and
// changes nothing on disk; the global pause also surfaces the teardown error
// on the folder.
func TestStreamUnmountFailureDoesNotPersist(t *testing.T) {
	cases := []struct {
		name  string
		call  func(m *Manager) (any, error)
		check func(t *testing.T, m *Manager, stream Folder)
	}{
		{"pause folder", func(m *Manager) (any, error) { return m.handlePauseFolder(json.RawMessage(`{"id":"stream"}`)) }, nil},
		{"remove folder", func(m *Manager) (any, error) { return m.handleRemoveFolder(json.RawMessage(`{"id":"stream"}`)) }, nil},
		{"global pause", func(m *Manager) (any, error) { return m.handlePauseAll(nil) }, func(t *testing.T, m *Manager, stream Folder) {
			if m.store.snapshotSettings().Paused {
				t.Fatal("global pause was persisted despite failed mount teardown")
			}
			if status := m.statusLocked(stream.ID); status.State != StateError || !strings.Contains(status.LastError, "device is busy") {
				t.Fatalf("mount teardown failure was not made visible: %+v", status)
			}
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := testManager(t)
			stream := Folder{ID: "stream", Name: "Stream", Remote: "gdrive", LocalPath: filepath.Join(t.TempDir(), "mount"), Mode: ModeStream}
			if err := m.store.putFolder(stream); err != nil {
				t.Fatalf("putFolder: %v", err)
			}
			fakeRC(t, m, map[string]http.HandlerFunc{
				"mount/unmount": errorRoute("device is busy"),
			})

			result, err := tc.call(m)
			if err == nil {
				t.Fatal("the action must fail when a stream could not be unmounted")
			}
			if result != nil {
				t.Fatalf("a failed action reported a success result: %#v", result)
			}
			stored, ok := m.store.folder(stream.ID)
			if !ok || !reflect.DeepEqual(stored, stream) {
				t.Fatalf("a failed action changed persisted folder state: %+v", stored)
			}
			if tc.check != nil {
				tc.check(t, m, stream)
			}
		})
	}
}
