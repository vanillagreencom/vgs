package server

import (
	"strconv"
	"testing"
	"time"
)

// parkSettle lets a consumer goroutine reach its wait before a test closes the
// queue under it.
const parkSettle = 200 * time.Millisecond

func TestQueueEntriesWithTheSameKeyCoalesce(t *testing.T) {
	q := newCoalescingQueue[string](8)

	if _, outcome := q.push("network", "first"); outcome != pushQueued {
		t.Fatalf("first push outcome = %v, want pushQueued", outcome)
	}
	if _, outcome := q.push("gamma", "gamma-only"); outcome != pushQueued {
		t.Fatalf("second push outcome = %v, want pushQueued", outcome)
	}
	replaced, outcome := q.push("network", "second")
	if outcome != pushReplaced {
		t.Fatalf("repeat key outcome = %v, want pushReplaced", outcome)
	}
	if replaced != "first" {
		t.Fatalf("replaced value = %q, want the entry that was overwritten", replaced)
	}
	if _, outcome := q.push("network", "third"); outcome != pushReplaced {
		t.Fatalf("second repeat outcome = %v, want pushReplaced", outcome)
	}

	if got := q.len(); got != 2 {
		t.Fatalf("queue length = %d, want 2: one entry per key", got)
	}
	// The replaced entry keeps its original position and carries the newest value.
	if v, _ := q.pop(); v != "third" {
		t.Fatalf("first popped = %q, want the newest value under the first key", v)
	}
	if v, _ := q.pop(); v != "gamma-only" {
		t.Fatalf("second popped = %q, want the second key's entry", v)
	}
}

func TestQueueEntriesWithNoKeyNeverCoalesce(t *testing.T) {
	q := newCoalescingQueue[string](8)
	for _, v := range []string{"one", "two", "three"} {
		if _, outcome := q.push("", v); outcome != pushQueued {
			t.Fatalf("push %q outcome = %v, want pushQueued: an unkeyed entry never replaces another", v, outcome)
		}
	}
	if got := q.len(); got != 3 {
		t.Fatalf("queue length = %d, want 3", got)
	}
}

func TestQueueReportsFullWithoutDiscardingEntries(t *testing.T) {
	q := newCoalescingQueue[string](3)
	for i := 0; i < 3; i++ {
		if _, outcome := q.push(strconv.Itoa(i), "v"); outcome != pushQueued {
			t.Fatalf("push %d outcome = %v, want pushQueued", i, outcome)
		}
	}
	if _, outcome := q.push("overflow", "v"); outcome != pushFull {
		t.Fatalf("push past the bound outcome = %v, want pushFull", outcome)
	}
	if got := q.len(); got != 3 {
		t.Fatalf("queue length = %d after a refused push, want the bound 3", got)
	}
}

// A consumer holding an entry must not have it rewritten underneath: the work
// is already under way, and the newer value would then never be delivered.
func TestQueuePoppedEntryIsNoLongerACoalescingTarget(t *testing.T) {
	q := newCoalescingQueue[string](8)
	q.push("network", "stale")
	q.push("network", "fresh")

	if v, ok := q.pop(); !ok || v != "fresh" {
		t.Fatalf("popped %q ok=%v, want the newest value", v, ok)
	}
	if _, outcome := q.push("network", "next"); outcome != pushQueued {
		t.Fatalf("push after pop outcome = %v, want pushQueued", outcome)
	}
	if v, ok := q.pop(); !ok || v != "next" {
		t.Fatalf("popped %q ok=%v, want the value pushed after the pop", v, ok)
	}
}

func TestQueuePopOnAClosedQueueReturnsAtOnce(t *testing.T) {
	q := newCoalescingQueue[string](8)
	q.close()

	done := make(chan bool, 1)
	go func() {
		_, ok := q.pop()
		done <- ok
	}()
	select {
	case ok := <-done:
		if ok {
			t.Fatal("pop reported an entry from a closed queue")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("pop blocked on a closed queue; the consumer goroutine would never exit")
	}

	if _, outcome := q.push("network", "v"); outcome != pushClosed {
		t.Fatalf("push after close outcome = %v, want pushClosed", outcome)
	}
	// close runs on shutdown paths that can overlap.
	q.close()
}

// A consumer already parked on an empty queue must be released too, or the
// goroutine outlives the connection or service that owned it.
func TestQueueCloseReleasesAParkedConsumer(t *testing.T) {
	q := newCoalescingQueue[string](8)
	popped := make(chan string, 1)
	done := make(chan bool, 1)
	go func() {
		v, _ := q.pop()
		popped <- v
		_, ok := q.pop()
		done <- ok
	}()

	q.push("", "first")
	select {
	case <-popped:
	case <-time.After(2 * time.Second):
		t.Fatal("the consumer never took the first entry")
	}
	// The consumer has taken its entry and gone back to an empty queue. Give it
	// time to park before closing: this test is about the parked case, which no
	// exported state reports.
	time.Sleep(parkSettle)

	q.close()
	select {
	case ok := <-done:
		if ok {
			t.Fatal("pop reported an entry after close")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("close left the consumer parked; its goroutine would never exit")
	}
}

// Advancing the head leaves the vacated slot pointing at the entry unless it is
// cleared, so a written frame's payload, or a queued call and its params, stays
// reachable until an append reallocates the backing array.
func TestQueuePopReleasesThePoppedEntry(t *testing.T) {
	q := newCoalescingQueue[string](8)
	q.push("", "first")
	q.push("", "second")

	// The pre-pop slice, whose index 0 is the slot pop advances past.
	vacated := q.entries
	if _, ok := q.pop(); !ok {
		t.Fatal("pop reported no entry")
	}
	if vacated[0] != nil {
		t.Fatalf("the popped slot still holds %+v; its payload stays reachable until the array reallocates", *vacated[0])
	}
}
