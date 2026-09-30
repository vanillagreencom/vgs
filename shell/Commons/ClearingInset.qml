import QtQml

QtObject {
    id: insetter

    property real pad: 0
    property real radius: 0
    property real width: 0
    property real height: 0
    // The corner step every component clears by: `inset.cornerStep`.
    property real step: Theme.inset.cornerStep
    // How far the content's top edge stands in from the container's.
    property real top: 0
    property real inset: pad
    property bool settlePending: false
    property bool alive: true

    // Height depends on wrap, wrap depends on inset, and inset depends on height.
    // A binding would loop. The map is monotone, so settling up from the pad reaches the least fixed point.
    function reset() {
        inset = pad;
        scheduleSettle();
    }

    function targetInset() {
        return Math.ceil(Inset.clearing(pad, radius, width, height, step, top));
    }

    function scheduleSettle() {
        if (settlePending || !alive) return;
        settlePending = true;
        Qt.callLater(settle);
    }

    function settle() {
        // Qt.callLater can run while the owner is being destroyed.
        if (!alive) return;
        settlePending = false;
        const next = targetInset();
        if (Math.abs(inset - next) <= 0.01) return;
        inset = next;
        scheduleSettle();
    }

    Component.onCompleted: scheduleSettle()
    Component.onDestruction: alive = false
    onPadChanged: reset()
    onRadiusChanged: reset()
    onWidthChanged: reset()
    onHeightChanged: scheduleSettle()
    onStepChanged: reset()
    onTopChanged: reset()
}
