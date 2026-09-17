package launchersearch

import (
	"container/heap"
	"os"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

// searchKind is the request's kind: which entries a search may return.
type searchKind int

const (
	kindFiles searchKind = iota
	kindFolders
	kindAll
)

func parseKind(raw string) (searchKind, bool) {
	switch raw {
	case "files":
		return kindFiles, true
	case "folders":
		return kindFolders, true
	case "all":
		return kindAll, true
	}
	return 0, false
}

func (k searchKind) String() string {
	switch k {
	case kindFiles:
		return "files"
	case kindFolders:
		return "folders"
	case kindAll:
		return "all"
	}
	panic("launchersearch: unknown search kind")
}

func (k searchKind) admits(isDir bool) bool {
	switch k {
	case kindFiles:
		return !isDir
	case kindFolders:
		return isDir
	case kindAll:
		return true
	}
	panic("launchersearch: unknown search kind")
}

const (
	flagDir  uint8 = 1 << 0
	flagDead uint8 = 1 << 1
)

// entry is one indexed name. Names live in one shared byte arena rather than
// one string each, since a home directory holds millions of entries. A root's
// name is its whole absolute path and its parent is -1.
type entry struct {
	parent  int32
	nameOff uint32
	nameLen uint16
	flags   uint8
}

// dirNode is what a directory needs for deltas: the watch that reports its
// changes and the children a re-listing compares against.
type dirNode struct {
	wd       int32
	children []int32
}

// index is the in-memory name index of one config. Only the goroutine that
// builds it, and after that its watch goroutine, write it; queries read under
// mu.RLock and every write holds mu.
type index struct {
	cfg     config
	builtAt time.Time

	mu      sync.RWMutex
	entries []entry
	names   []byte
	dirs    map[int32]*dirNode
	byWd    map[int32][]int32
	rootDev map[int32]uint64
	dead    int

	// degraded is set once the watches can no longer be trusted to report every
	// change: the kernel's watch limit was reached, its event queue overflowed,
	// or the event reader stopped. The index keeps answering, and the manager
	// replaces it with a fresh walk.
	degraded atomic.Bool
	watch    *watcher
}

func newIndex(cfg config) *index {
	return &index{
		cfg:     cfg,
		dirs:    map[int32]*dirNode{},
		byWd:    map[int32][]int32{},
		rootDev: map[int32]uint64{},
	}
}

// add appends one entry under parent and returns its position. The caller
// holds mu.
func (ix *index) add(parent int32, name string, isDir bool) int32 {
	if len(name) > 0xffff {
		name = name[:0xffff]
	}
	e := entry{parent: parent, nameOff: uint32(len(ix.names)), nameLen: uint16(len(name))}
	if isDir {
		e.flags = flagDir
	}
	ix.names = append(ix.names, name...)
	pos := int32(len(ix.entries))
	ix.entries = append(ix.entries, e)
	if isDir {
		ix.dirs[pos] = &dirNode{wd: -1}
	}
	if parent >= 0 {
		node := ix.dirs[parent]
		node.children = append(node.children, pos)
	}
	return pos
}

func (ix *index) name(pos int32) []byte {
	e := ix.entries[pos]
	return ix.names[e.nameOff : e.nameOff+uint32(e.nameLen)]
}

// path rebuilds an entry's absolute path from its parent chain.
func (ix *index) path(pos int32) string {
	var parts []string
	for p := pos; p >= 0; p = ix.entries[p].parent {
		parts = append(parts, string(ix.name(p)))
	}
	var b strings.Builder
	for i := len(parts) - 1; i >= 0; i-- {
		// A root of "/" already ends in the separator.
		if i != len(parts)-1 && !strings.HasSuffix(b.String(), "/") {
			b.WriteByte('/')
		}
		b.WriteString(parts[i])
	}
	return b.String()
}

// live counts the entries a search can still return.
func (ix *index) live() int {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	return len(ix.entries) - ix.dead
}

// wornOut reports that removed entries outnumber the live ones, so a fresh walk
// would hold the same answers in less memory.
func (ix *index) wornOut() bool {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	return ix.dead > len(ix.entries)-ix.dead
}

// hit is one search result, in the shape `vshell launcher-search search`
// prints, so a QML consumer reads either answer the same way.
type hit struct {
	Path   string  `json:"path"`
	Name   string  `json:"name"`
	Parent string  `json:"parent"`
	IsDir  bool    `json:"is_dir"`
	Size   int64   `json:"size"`
	Mtime  int64   `json:"mtime"`
	Score  float64 `json:"score"`
}

// search ranks the live entries whose names match query. Scores rank first;
// among the best candidates, a more recently modified entry ranks before an
// older one and the path breaks what remains.
func (ix *index) search(query string, kind searchKind, limit int) []hit {
	needle := []rune(strings.ToLower(query))
	if len(needle) == 0 || limit <= 0 {
		return []hit{}
	}
	// Only the candidates that could reach the result are stat'ed for their
	// modification time, but ties on score are common, so the pool is wider
	// than the limit.
	pool := limit * 4
	asciiNeedle := make([]byte, 0, len(needle))
	for _, r := range needle {
		if r >= utf8.RuneSelf {
			asciiNeedle = nil
			break
		}
		asciiNeedle = append(asciiNeedle, byte(r))
	}

	ix.mu.RLock()
	total := len(ix.entries)
	workers := runtime.GOMAXPROCS(0)
	if workers > total/4096+1 {
		workers = total/4096 + 1
	}
	chunk := (total + workers - 1) / workers
	tops := make([]candidates, workers)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		start := w * chunk
		end := min(start+chunk, total)
		wg.Add(1)
		go func(w, start, end int) {
			defer wg.Done()
			top := candidates{}
			for pos := start; pos < end; pos++ {
				e := ix.entries[pos]
				if e.flags&flagDead != 0 || e.parent < 0 || !kind.admits(e.flags&flagDir != 0) {
					continue
				}
				s, ok := score(ix.names[e.nameOff:e.nameOff+uint32(e.nameLen)], needle, asciiNeedle)
				if !ok {
					continue
				}
				top.offer(candidate{score: s, pos: int32(pos)}, pool)
			}
			tops[w] = top
		}(w, start, end)
	}
	wg.Wait()

	var merged candidates
	for _, top := range tops {
		for _, c := range top {
			merged.offer(c, pool)
		}
	}
	paths := make([]string, len(merged))
	dirs := make([]bool, len(merged))
	for i, c := range merged {
		paths[i] = ix.path(c.pos)
		dirs[i] = ix.entries[c.pos].flags&flagDir != 0
	}
	ix.mu.RUnlock()

	hits := make([]hit, 0, len(merged))
	for i, c := range merged {
		info, err := os.Stat(paths[i])
		if err != nil {
			// Removed since the last delta reached the index.
			continue
		}
		slash := strings.LastIndexByte(paths[i], '/')
		parent := paths[i][:slash]
		if parent == "" {
			parent = "/"
		}
		hits = append(hits, hit{
			Path:   paths[i],
			Name:   paths[i][slash+1:],
			Parent: parent,
			IsDir:  dirs[i],
			Size:   info.Size(),
			Mtime:  info.ModTime().Unix(),
			Score:  c.score,
		})
	}
	sort.Slice(hits, func(a, b int) bool {
		if hits[a].Score != hits[b].Score {
			return hits[a].Score > hits[b].Score
		}
		if hits[a].Mtime != hits[b].Mtime {
			return hits[a].Mtime > hits[b].Mtime
		}
		return strings.ToLower(hits[a].Path) < strings.ToLower(hits[b].Path)
	})
	if len(hits) > limit {
		hits = hits[:limit]
	}
	return hits
}

// score is the launcher's fuzzy name score, case-insensitive. A name holding
// the query as a substring scores above any that holds it only as a
// subsequence; earlier substrings, smaller gaps and shorter names score higher.
// ok is false for a name that does not hold every query character in order.
func score(name []byte, needle []rune, asciiNeedle []byte) (float64, bool) {
	if asciiNeedle != nil && isASCII(name) {
		return scoreASCII(name, asciiNeedle)
	}
	return scoreRunes([]rune(strings.ToLower(string(name))), needle)
}

func isASCII(b []byte) bool {
	for _, c := range b {
		if c >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

func lowerASCII(c byte) byte {
	if 'A' <= c && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

func scoreASCII(hay, needle []byte) (float64, bool) {
	extra := float64(max(0, len(hay)-len(needle)))
	for i := 0; i+len(needle) <= len(hay); i++ {
		j := 0
		for j < len(needle) && lowerASCII(hay[i+j]) == needle[j] {
			j++
		}
		if j == len(needle) {
			return 1000 - float64(i)*2 - extra*0.15, true
		}
	}
	pos, gap := -1, 0
	for _, want := range needle {
		next := pos + 1
		for next < len(hay) && lowerASCII(hay[next]) != want {
			next++
		}
		if next >= len(hay) {
			return 0, false
		}
		if pos >= 0 {
			gap += next - pos - 1
		}
		pos = next
	}
	return 650 - float64(gap)*4 - extra*0.1, true
}

func scoreRunes(hay, needle []rune) (float64, bool) {
	extra := float64(max(0, len(hay)-len(needle)))
	for i := 0; i+len(needle) <= len(hay); i++ {
		j := 0
		for j < len(needle) && hay[i+j] == needle[j] {
			j++
		}
		if j == len(needle) {
			return 1000 - float64(i)*2 - extra*0.15, true
		}
	}
	pos, gap := -1, 0
	for _, want := range needle {
		next := pos + 1
		for next < len(hay) && hay[next] != want {
			next++
		}
		if next >= len(hay) {
			return 0, false
		}
		if pos >= 0 {
			gap += next - pos - 1
		}
		pos = next
	}
	return 650 - float64(gap)*4 - extra*0.1, true
}

type candidate struct {
	score float64
	pos   int32
}

// candidates is a bounded min-heap: its root is the weakest candidate kept, so
// a stronger one replaces it once the heap is full.
type candidates []candidate

func (h candidates) Len() int { return len(h) }
func (h candidates) Less(i, j int) bool {
	if h[i].score != h[j].score {
		return h[i].score < h[j].score
	}
	return h[i].pos > h[j].pos
}
func (h candidates) Swap(i, j int) { h[i], h[j] = h[j], h[i] }
func (h *candidates) Push(x any)   { *h = append(*h, x.(candidate)) }
func (h *candidates) Pop() any {
	old := *h
	last := old[len(old)-1]
	*h = old[:len(old)-1]
	return last
}

func (h *candidates) offer(c candidate, bound int) {
	if h.Len() < bound {
		heap.Push(h, c)
		return
	}
	weakest := (*h)[0]
	if c.score > weakest.score || (c.score == weakest.score && c.pos < weakest.pos) {
		(*h)[0] = c
		heap.Fix(h, 0)
	}
}
