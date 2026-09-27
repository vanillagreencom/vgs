package server

import "sync"

// pushOutcome says what a push did. Callers match it exhaustively: a full queue
// and a replaced entry both need an answer sent to whoever was waiting.
type pushOutcome int

const (
	// pushQueued: the entry took a new place at the back of the queue.
	pushQueued pushOutcome = iota
	// pushReplaced: an entry under the same key was still waiting and has been
	// overwritten. The replaced value is returned with this outcome.
	pushReplaced
	// pushFull: the queue is at its bound and nothing was added.
	pushFull
	// pushClosed: the queue is closed and nothing was added.
	pushClosed
)

// coalescingQueue is a bounded FIFO whose entries may carry a key. Pushing an
// entry whose key matches one still waiting overwrites that entry in place,
// keeping its queue position, so a slow consumer sees the newest value of each
// key instead of a backlog. An entry with an empty key never coalesces.
//
// The zero value is not usable; use newCoalescingQueue.
type coalescingQueue[T any] struct {
	mu      sync.Mutex
	cond    *sync.Cond
	entries []*queued[T]
	waiting map[string]*queued[T]
	depth   int
	closed  bool
}

type queued[T any] struct {
	key   string
	value T
}

func newCoalescingQueue[T any](depth int) *coalescingQueue[T] {
	q := &coalescingQueue[T]{waiting: map[string]*queued[T]{}, depth: depth}
	q.cond = sync.NewCond(&q.mu)
	return q
}

// push adds value under key. A non-empty key that is still waiting is
// overwritten and its previous value returned with pushReplaced.
func (q *coalescingQueue[T]) push(key string, value T) (T, pushOutcome) {
	var none T
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return none, pushClosed
	}
	if key != "" {
		if entry, ok := q.waiting[key]; ok {
			replaced := entry.value
			entry.value = value
			return replaced, pushReplaced
		}
	}
	if len(q.entries) >= q.depth {
		return none, pushFull
	}
	entry := &queued[T]{key: key, value: value}
	q.entries = append(q.entries, entry)
	if key != "" {
		q.waiting[key] = entry
	}
	q.cond.Signal()
	return none, pushQueued
}

// pop blocks until an entry is available, then hands it to the caller. An
// entry the consumer holds is no longer a coalescing target: overwriting it
// would rewrite work already under way. pop reports false once the queue is
// closed.
func (q *coalescingQueue[T]) pop() (T, bool) {
	var none T
	q.mu.Lock()
	defer q.mu.Unlock()
	for len(q.entries) == 0 && !q.closed {
		q.cond.Wait()
	}
	if q.closed {
		return none, false
	}
	entry := q.entries[0]
	// Clear the slot before advancing: the backing array keeps the old element
	// reachable otherwise, holding a written frame's payload, or a queued call's
	// params, until an append reallocates.
	q.entries[0] = nil
	q.entries = q.entries[1:]
	if q.waiting[entry.key] == entry {
		delete(q.waiting, entry.key)
	}
	return entry.value, true
}

// len reports how many entries are waiting for the consumer.
func (q *coalescingQueue[T]) len() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.entries)
}

// close drops what is queued and releases the consumer parked in pop.
func (q *coalescingQueue[T]) close() {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.closed {
		return
	}
	q.closed = true
	q.entries = nil
	q.waiting = nil
	q.cond.Broadcast()
}
