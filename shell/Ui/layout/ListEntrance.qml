import QtQuick
import qs.Commons
import qs.Ui
import "ListCursorLogic.js" as Logic

// A row's entrance, as its `transform`: the row rises `motion.rise` into
// place, or slides `shift` in from the side `start` names, while `progress`
// runs from 0 to 1, and the row binds its opacity to `progress`. `start`
// waits one `motion.stagger` for each row that arrived before it in its
// turn, up to `motion.staggerRows`, then enters over `motion.enter`. At
// `motion.scale` 0 both are 0, and Qt finishes an animation of no duration
// as it starts, so `start` leaves the row in place at once.
Translate {
    id: root

    // The timings and the rise, in the shape of `Theme.motion.list`, as
    // ListCursor takes them.
    property var motion: Theme.motion.list
    // How far a row slides in from the side.
    property real shift: 0
    // 0 hidden, 1 in place.
    property real progress: 1
    // 0 rises from below; 1 slides in from the right, -1 from the left.
    property int direction: 0

    x: (1 - progress) * direction * shift
    y: direction === 0 ? (1 - progress) * motion.rise : 0

    // Enter as the `slot`-th row of its turn, from `from`, a `direction`.
    function start(slot, from) {
        run.stop();
        direction = from;
        progress = 0;
        run.delay = Logic.enterDelay(slot, motion.stagger, motion.staggerRows);
        run.start();
    }

    readonly property SequentialAnimation run: SequentialAnimation {
        property int delay: 0
        PauseAnimation { duration: root.run.delay }
        ListAnimation { target: root; property: "progress"; to: 1; step: root.motion.enter }
    }
}
