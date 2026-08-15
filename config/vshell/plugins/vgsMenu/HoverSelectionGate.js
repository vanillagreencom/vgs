// The launcher's hover-selection latch (VGS-134), as pure functions over an
// explicit state value: `HoverSelectionGate.qml` holds the state and forwards
// to these, and `scripts/test-launcher-hover-latch.js` requires this module and
// runs the shipped decision itself.
//
// WHY THE LATCH EXISTS. A launcher's result list rebuilds under the pointer
// while the query changes, so `MouseArea.onEntered` fires for whichever row
// happens to land beneath a mouse that never moved. That is indistinguishable
// from a real hover, and it drags the highlight off the keyboard's item — type,
// press Enter, and launch whatever the cursor was resting over. Hover therefore
// starts DORMANT and arms only once the pointer has physically travelled.
//
// WHY TRAVEL IS MEASURED FROM AN ANCHOR rather than from the previous report:
// a slow drag reports a string of 1px steps, and each one compared against its
// predecessor is below any usable threshold, so hover would never re-arm. The
// anchor is the position the pointer held when the keyboard last took over.
//
// WHY THE CALLER MUST PASS A SCENE POSITION. `mouse.x`/`mouse.y` are in the
// item's own coordinates, which shift when the list rebuilds or scrolls under a
// still cursor — the exact confusion the latch exists to end. Callers do not
// choose: `HoverSelectionGate.notePointer(area, mouse)` does the mapping.

// Pixels of travel that count as a real mouse movement. Small enough that a
// deliberate nudge arms hover, large enough to absorb the sub-pixel jitter a
// resting pointer reports on a scaled output.
var MOTION_THRESHOLD = 2;

// The keyboard owns selection and hover is dormant, with no anchor yet — the
// state a launcher opens in, and the state disarming returns to. Clearing the
// anchor is what makes the NEXT pointer report re-anchor rather than read as
// travel: the cursor may have been moving when the key arrived, and measuring
// from the old anchor would then arm hover on a keystroke.
function emptyState() {
    return {
        armed: false,
        anchorX: NaN,
        anchorY: NaN
    };
}

// Records a scene-coordinate pointer position. `hoverOwnsSelection` is true
// when hover may drive selection, i.e. the pointer has really moved since the
// keyboard last took over. `state` is returned unchanged (same reference) when
// nothing was decided, so the caller can skip a write.
function notePointer(state, sceneX, sceneY) {
    var current = state || emptyState();
    if (current.armed) {
        return {
            state: current,
            hoverOwnsSelection: true
        };
    }
    if (isNaN(current.anchorX) || isNaN(current.anchorY)) {
        return {
            state: {
                armed: false,
                anchorX: sceneX,
                anchorY: sceneY
            },
            hoverOwnsSelection: false
        };
    }
    if (Math.abs(sceneX - current.anchorX) <= MOTION_THRESHOLD
        && Math.abs(sceneY - current.anchorY) <= MOTION_THRESHOLD) {
        return {
            state: current,
            hoverOwnsSelection: false
        };
    }
    return {
        state: {
            armed: true,
            anchorX: sceneX,
            anchorY: sceneY
        },
        hoverOwnsSelection: true
    };
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        MOTION_THRESHOLD: MOTION_THRESHOLD,
        emptyState: emptyState,
        notePointer: notePointer
    };
}
