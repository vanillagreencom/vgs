// Package launchersearch owns the launcher's file and folder name index. The
// first request walks the configured roots once; after that, inotify reports
// each directory whose names changed and only that directory is listed again,
// so a search reads memory instead of walking the disk per keystroke.
package launchersearch

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"

	"vshell/backend/internal/recovery"
	"vshell/backend/internal/server"
)

// degradedRebuildAfter bounds how often an index whose watches stopped
// reporting every change is replaced by a fresh walk. The walk is the cost the
// index exists to avoid, so a machine past its inotify watch limit pays it at
// most this often, and only while someone is searching.
var degradedRebuildAfter = 5 * time.Minute

const (
	defaultLimit = 80
	maxLimit     = 300
)

// Manager holds the one index the settings describe. A request with different
// settings replaces it.
type Manager struct {
	log *slog.Logger
	ctx context.Context
	end context.CancelFunc

	mu       sync.Mutex
	changed  *sync.Cond
	current  *index
	building *build
	closed   bool
}

// build is one walk in progress, or finished with err set when it failed.
type build struct {
	key      string
	finished bool
	err      error
}

type configParams struct {
	Roots        []string `json:"roots"`
	Ignores      []string `json:"ignores"`
	IgnoreMounts bool     `json:"ignoreMounts"`
}

type queryParams struct {
	configParams
	Query string `json:"query"`
	Kind  string `json:"kind"`
	Limit int    `json:"limit"`
}

func Register(srv *server.Server, log *slog.Logger) (*Manager, error) {
	if log == nil {
		log = slog.Default()
	}
	m := newManager(log)
	srv.Register("launcher.search", "launcher.search.prepare", m.handlePrepare)
	// A newer query replaces one of its kind still waiting, so typing never
	// queues a search per keystroke behind the one running.
	srv.RegisterLatest("launcher.search", "launcher.search.query", m.handleQuery, queryKey)
	return m, nil
}

// queryKey separates kinds: a surface that switches from files to folders is
// still owed its folders answer, while a newer query of one kind makes the
// older one's answer worthless.
func queryKey(params json.RawMessage) string {
	var p struct {
		Kind string `json:"kind"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		// Unreadable params coalesce with nothing, and the handler reports them.
		return ""
	}
	return "kind:" + p.Kind
}

func newManager(log *slog.Logger) *Manager {
	ctx, end := context.WithCancel(context.Background())
	m := &Manager{log: log, ctx: ctx, end: end}
	m.changed = sync.NewCond(&m.mu)
	return m
}

func (m *Manager) Close() {
	m.mu.Lock()
	m.closed = true
	current := m.current
	m.current = nil
	m.changed.Broadcast()
	m.mu.Unlock()
	m.end()
	if current != nil {
		current.close()
	}
}

// handlePrepare starts the walk for these settings when no index holds them,
// and returns without waiting for it. A surface calls it as it opens, so the
// walk is usually done by the time a query arrives.
func (m *Manager) handlePrepare(params json.RawMessage) (any, error) {
	var p configParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	cfg, err := newConfig(p.Roots, p.Ignores, p.IgnoreMounts)
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return nil, errors.New("launcher search is shutting down")
	}
	if m.current == nil || m.current.cfg.key != cfg.key || m.current.needsRebuild() {
		m.startBuildLocked(cfg)
	}
	return map[string]any{"success": true}, nil
}

func (m *Manager) handleQuery(params json.RawMessage) (any, error) {
	var p queryParams
	if err := decode(params, &p); err != nil {
		return nil, err
	}
	kind, ok := parseKind(p.Kind)
	if !ok {
		return nil, fmt.Errorf("unknown search kind %q", p.Kind)
	}
	limit := p.Limit
	if limit <= 0 {
		limit = defaultLimit
	}
	limit = min(limit, maxLimit)
	query := strings.TrimSpace(p.Query)
	cfg, err := newConfig(p.Roots, p.Ignores, p.IgnoreMounts)
	if err != nil {
		return nil, err
	}
	ix, err := m.indexFor(cfg)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"ok":    true,
		"kind":  kind.String(),
		"query": query,
		"hits":  ix.search(query, kind, limit),
	}, nil
}

// indexFor returns the index for cfg, waiting for its walk when none holds
// these settings yet. An index that needs replacing keeps answering while its
// replacement is walked.
func (m *Manager) indexFor(cfg config) (*index, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for {
		if m.closed {
			return nil, errors.New("launcher search is shutting down")
		}
		if cur := m.current; cur != nil && cur.cfg.key == cfg.key {
			if cur.needsRebuild() {
				m.startBuildLocked(cfg)
			}
			return cur, nil
		}
		b := m.startBuildLocked(cfg)
		for !b.finished && !m.closed {
			m.changed.Wait()
		}
		if b.key == cfg.key && b.err != nil {
			return nil, b.err
		}
	}
}

// startBuildLocked starts a walk for cfg unless one is already running, and
// returns the walk in progress. One walk runs at a time: a request for other
// settings waits for it, then starts its own.
func (m *Manager) startBuildLocked(cfg config) *build {
	if m.building != nil {
		return m.building
	}
	// A machine where the last index for these settings ran out of watches is
	// walked without them; watching would only take the limit again.
	watched := true
	if cur := m.current; cur != nil && cur.cfg.key == cfg.key && cur.unwatched.Load() {
		watched = false
	}
	if cur := m.current; cur != nil {
		// The budget is the service's, not each index's: the walk may take it
		// all, so the index it replaces gives its watches up first and answers
		// from memory until the replacement lands.
		cur.degraded.Store(true)
		cur.close()
	}
	b := &build{key: cfg.key}
	m.building = b
	go func() {
		started := time.Now()
		var ix *index
		// Kept only when the walk panics: waiters must still be released, with
		// a failure rather than an index.
		err := errors.New("launcher search index walk panicked")
		recovery.Run(m.log, "launchersearch.build", func() {
			ix, err = buildIndex(m.ctx, cfg, m.log, watched)
		})
		m.mu.Lock()
		defer m.mu.Unlock()
		b.finished, b.err = true, err
		m.building = nil
		m.changed.Broadcast()
		if err != nil {
			if !errors.Is(err, context.Canceled) {
				m.log.Warn("launcher search index walk failed", "err", err)
			}
			return
		}
		if m.closed {
			ix.close()
			return
		}
		old := m.current
		m.current = ix
		if old != nil {
			old.close()
		}
		m.log.Info("launcher search index ready", "entries", ix.live(),
			"elapsed", time.Since(started).Round(time.Millisecond), "degraded", ix.degraded.Load())
	}()
	return b
}

// needsRebuild reports an index whose answers a fresh walk would improve: it
// missed changes, including by holding no watches, or removals left it holding
// more dead entries than live ones. A replacement is walked at most once per
// degradedRebuildAfter.
func (ix *index) needsRebuild() bool {
	if time.Since(ix.builtAt) < degradedRebuildAfter {
		return false
	}
	return ix.degraded.Load() || ix.wornOut()
}

// watchLimit reads the per-user inotify watch limit, which every program the
// user runs draws from. Tests replace it.
var watchLimit = func() (int64, error) {
	raw, err := os.ReadFile("/proc/sys/fs/inotify/max_user_watches")
	if err != nil {
		return 0, err
	}
	return strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64)
}

// buildIndex walks cfg's roots into a new index and, when watched, starts
// watching it. The index stops adding watches at half the user's watch limit.
func buildIndex(ctx context.Context, cfg config, log *slog.Logger, watched bool) (*index, error) {
	ix := newIndex(cfg, log)
	if watched {
		limit, err := watchLimit()
		switch {
		case err != nil:
			ix.unwatched.Store(true)
			ix.degrade("the inotify watch limit could not be read", "err", err)
		default:
			ix.watchBudget = limit / 2
			if w, err := newWatcher(log); err != nil {
				ix.degrade("inotify is unavailable", "err", err)
			} else {
				ix.watch = w
			}
		}
	} else {
		ix.unwatched.Store(true)
		ix.degraded.Store(true)
	}
	var starts []dirJob
	for _, root := range cfg.roots {
		if cfg.ignores.ignoredRoot(root) {
			continue
		}
		var st unix.Stat_t
		if err := unix.Stat(root, &st); err != nil {
			continue
		}
		pos := ix.add(-1, root, true, fileID{dev: st.Dev, ino: st.Ino})
		ix.rootDev[pos] = st.Dev
		starts = append(starts, dirJob{pos: pos, path: root, dev: st.Dev})
	}
	if err := ix.walk(ctx, starts); err != nil {
		ix.close()
		return nil, err
	}
	// Appending grew both arrays by doubling; a walked home directory is large
	// enough that the unused capacity is worth returning.
	ix.entries = slices.Clone(ix.entries)
	ix.names = slices.Clone(ix.names)
	ix.builtAt = time.Now()
	if ix.watch != nil && !ix.unwatched.Load() {
		go ix.watchChanges()
	}
	return ix, nil
}

func (ix *index) close() {
	if ix.watch != nil {
		ix.watch.close()
	}
}

func decode(params json.RawMessage, into any) error {
	if len(params) == 0 {
		return nil
	}
	return json.Unmarshal(params, into)
}
