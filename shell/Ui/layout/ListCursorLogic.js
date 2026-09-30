.pragma library

// ListCursor's decisions, with no QML objects, so scripts/test-list-cursor-
// logic.js runs them under node: whether the pointer moved between two
// readings, and how long a row that arrives waits before it enters.

// Half a step of wl_fixed_t, the 24.8 fixed-point number Wayland reports a
// pointer position in: two positions closer than this are one position.
var POINTER_EPSILON = 1 / 512;

// Whether the pointer moved from `last` to `at`, two scene points; `last`
// is null before the first reading, which moves nothing. Qt delivers hover
// again to a row that moves under a still pointer, as a list scrolls or a
// card animates, and a point mapped back from a moving item differs by
// float roundoff (docs/architecture/runtime-pointer.md): an exact
// comparison reads that as motion, and the resting pointer takes the
// cursor.
function pointerMoved(last, at) {
    if (last === null) return false;
    return Math.abs(at.x - last.x) >= POINTER_EPSILON || Math.abs(at.y - last.y) >= POINTER_EPSILON;
}

// The wait before the row that arrives `slot`-th in one turn enters: one
// `stagger` per row before it, counted up to `staggerRows`, so a long list
// fills in no longer than its first rows take.
function enterDelay(slot, stagger, staggerRows) {
    return Math.min(slot, staggerRows) * stagger;
}
