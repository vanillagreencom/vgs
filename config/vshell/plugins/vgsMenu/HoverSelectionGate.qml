import QtQuick
import "./HoverSelectionGate.js" as Latch

// Holds the launcher's hover-selection latch state and forwards every decision
// to HoverSelectionGate.js, which is where the reasoning and the regression
// test both live. Nothing is decided here.
//
// It lives beside its one consumer rather than in `Widgets/Launcher/`, which
// holds shared components only (docs/architecture/shell-architecture.md §
// "Core and the vgsMenu plugin"). The app-picker delegates solve the same
// problem their own way; if they ever adopt this, it moves there then.
QtObject {
    property var latchState: Latch.emptyState()

    // False means the keyboard owns selection and hover is dormant. Only
    // SELECTION and the hover tint follow it — cursor shape, click,
    // double-click and the right-click menu keep working throughout.
    readonly property bool armed: latchState.armed

    // The keyboard takes selection: called on launcher open, on every key, on
    // every query change, and whenever the result list is repopulated. Opening
    // and disarming are the same state, so both are `emptyState()`.
    function disarm() {
        latchState = Latch.emptyState();
    }

    // Call from a hovering MouseArea's onPositionChanged, passing that area and
    // the event. Returns true when hover may take selection. The area is mapped
    // to SCENE coordinates here so no caller can pass item-local ones, which
    // move under a still cursor as the list rebuilds.
    //
    // A scene position is window-local: it is stable under a resting pointer
    // because menuWindow's geometry derives only from screen metrics, and the
    // one path that moves the window — `open()` reassigning `menuWindow.screen`
    // — disarms immediately afterwards through `resetLauncherState()`. Moving
    // that geometry off screen metrics would need this re-checked.
    function notePointer(area, mouse) {
        const scene = area.mapToItem(null, mouse.x, mouse.y);
        const transition = Latch.notePointer(latchState, scene.x, scene.y);
        if (transition.state !== latchState)
            latchState = transition.state;
        return transition.hoverOwnsSelection;
    }
}
