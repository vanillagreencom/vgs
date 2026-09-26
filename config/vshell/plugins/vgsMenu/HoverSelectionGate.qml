import QtQuick
import "./HoverSelectionGate.js" as Latch

// Store hover latch state and delegate decisions to HoverSelectionGate.js.
QtObject {
    property var latchState: Latch.emptyState()

    // The latch gates selection and hover tint. Click and context-menu actions
    // remain available while the keyboard owns selection.
    readonly property bool armed: latchState.armed

    // Give selection to the keyboard and reset the pointer anchor.
    function disarm() {
        latchState = Latch.emptyState();
    }

    // Map a MouseArea event into scene coordinates and return whether hover
    // may take selection. Item coordinates move when rows rebuild.
    // Scene coordinates assume stable window geometry. A screen scale or
    // resolution change can arm hover early; deliberate screen reassignment
    // must disarm the latch through resetLauncherState.
    function notePointer(area, mouse) {
        const scene = area.mapToItem(null, mouse.x, mouse.y);
        const transition = Latch.notePointer(latchState, scene.x, scene.y);
        if (transition.state !== latchState)
            latchState = transition.state;
        return transition.hoverOwnsSelection;
    }
}
