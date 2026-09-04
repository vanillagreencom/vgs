// Latch hover until the pointer moves after keyboard selection. Result-list
// rebuilds can synthesize onEntered under a stationary pointer.
// Measure travel from an anchor so small successive movements accumulate.
// Callers must use scene coordinates; item coordinates change when rows move.
// scripts/test-launcher-hover-latch.js requires this module and mutation-tests it.

// Absorb resting-pointer jitter while allowing a deliberate nudge.
var MOTION_THRESHOLD = 2;

// Return the disarmed state. Clear the anchor so the next pointer report
// cannot count motion from before keyboard selection took control.
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
