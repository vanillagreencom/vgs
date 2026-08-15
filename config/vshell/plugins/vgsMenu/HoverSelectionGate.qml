import QtQuick

// Keeps hover from stealing keyboard selection under a stationary cursor.
//
// A launcher's result list rebuilds under the pointer while the query changes,
// so `MouseArea.onEntered` fires for whichever row happens to land beneath a
// mouse that never moved. That is indistinguishable from a real hover, and it
// drags the highlight off the keyboard's item — type, press Enter, and launch
// whatever the cursor was resting over (VGS-134). Hover therefore starts
// DORMANT and only arms once the pointer has physically travelled.
//
// `onPositionChanged` alone cannot be the re-arm signal: it fires when an item
// moves under a still cursor too, because the position it reports is in the
// item's own coordinates, which shift as the list rebuilds and scrolls.
// Callers pass a SCENE position (`mapToItem(null, mouse.x, mouse.y)`), which
// stays put exactly when the pointer does.
//
// Only SELECTION is gated. Hover highlight (`containsMouse`), cursor shape,
// clicks and context menus are untouched and keep working throughout.
//
// It lives beside its one consumer rather than in `Widgets/Launcher/`, which
// holds shared components only (docs/architecture/shell-architecture.md §
// "Core and the vgsMenu plugin"). The app-picker delegates solve the same
// problem their own way; if they ever adopt this, it moves there then.
QtObject {
    // False means the keyboard owns selection and hover is dormant.
    property bool armed: false

    // Pixels of scene-space travel that count as a real mouse movement. Small
    // enough that a deliberate nudge arms hover, large enough to absorb the
    // sub-pixel jitter a resting pointer reports on a scaled output.
    readonly property real motionThreshold: 2

    // Pointer position when the keyboard last took over, NaN until the first
    // pointer event after that. Movement is measured from this anchor rather
    // than from the previous event, so a slow drag accumulates instead of
    // reading as an endless string of sub-threshold no-ops.
    property real anchorX: NaN
    property real anchorY: NaN

    // BEGIN HOVER LATCH DECISION
    // Plain JavaScript over plain state, with no QML API in it, so
    // scripts/test-launcher-hover-latch.js can extract this block and run the
    // shipped decision instead of asserting on the shape of its source.

    // The keyboard takes selection: call on launcher open and on every key.
    // Clearing the anchor as well is what makes the NEXT pointer event a
    // re-anchor rather than a movement — the cursor may have been moving when
    // the key arrived, and its old anchor would then read as travel.
    function disarm() {
        armed = false;
        anchorX = NaN;
        anchorY = NaN;
    }

    // Records a scene-coordinate pointer position. Returns true when hover may
    // drive selection, i.e. the pointer has really moved since the keyboard
    // last took over.
    function notePointer(sceneX, sceneY) {
        if (armed)
            return true;
        if (isNaN(anchorX) || isNaN(anchorY)) {
            anchorX = sceneX;
            anchorY = sceneY;
            return false;
        }
        if (Math.abs(sceneX - anchorX) <= motionThreshold
            && Math.abs(sceneY - anchorY) <= motionThreshold)
            return false;
        armed = true;
        return true;
    }
    // END HOVER LATCH DECISION
}
