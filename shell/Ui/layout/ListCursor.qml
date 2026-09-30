import QtQuick
import qs.Commons
import qs.Ui
import "ListCursorLogic.js" as Logic

// The one cursor of a list: a plate under the row that holds the list's
// selection. It travels to the next row and takes its height rather than
// lighting each row, fades in while `shown` and out while not, and lands at
// once after `snap()` and while hidden, so it appears where it lands.
// `shown` holds while a row holds the cursor; a list that knows whether it
// has a selection, and rebuilds its rows under it, binds it instead, so a
// row it destroys leaves the plate in place for the next.
//
// Keyboard and pointer move the same selection, which the list owns. A row
// hands the cursor itself through `follow(row, holds)` while it holds the
// selection. A hover moves the selection only once `hoverTakes` answers
// true: after `disarm()`, which a keyboard step and a rebuilt list call,
// the pointer must move before it takes the selection again, so a pointer
// resting over a list that moves under it never takes the selection from
// the keyboard.
//
// Declare the cursor in the item that holds the rows, or in any item above
// them that is not a positioner, such as a view's contentItem. It follows
// the row through every item between, by their positions, so it ignores a
// row's transform, such as its entrance. `enterSlot()` places a row that
// arrives among the others of its turn, for ListEntrance.
//
// Every timing and distance is `motion`, `Theme.motion.list` by default. A
// plugin that owns its look hands its own, in the same shape, and its own
// `background`.
Item {
    id: root

    property var motion: Theme.motion.list
    // The default plate's fill and corner; a replaced `background` draws
    // its own.
    property color color: Theme.listItem.selected
    property real radius: Theme.listItem.radius
    // What the plate draws. The cursor parents it and fills itself with it.
    property Item background: Rectangle { color: root.color; radius: root.radius }
    // The row that holds the selection; null for none.
    readonly property alias target: state.target
    // Whether a hover moves the selection: the pointer has moved since the
    // last `disarm()`.
    readonly property alias armed: state.armed
    property bool shown: target !== null

    z: -1
    opacity: shown ? 1 : 0
    // A plate faded out takes no room, so a scroll area that measures its
    // children skips it.
    visible: opacity > 0
    Behavior on opacity {
        enabled: root.motion.fade.duration > 0
        ListAnimation { step: root.motion.fade }
    }

    // `holds` true hands the cursor `row`; false lets it go, unless another
    // row took it first. A row that lets go before the next row takes it
    // leaves the cursor travelling between them, since the plate is still
    // shown when the next row takes it. A row outside the cursor's parent is
    // refused with an error, and the cursor stays where it was.
    function follow(row, holds) {
        if (holds) {
            if (chainOf(row) === null) {
                console.error("ListCursor: row " + row + " is not inside the cursor's parent " + root.parent);
                return;
            }
            state.target = row;
        } else if (state.target === row) state.target = null;
    }

    // The next placement, this turn, lands at once.
    function snap() {
        state.snapping = true;
        Qt.callLater(state.settle);
    }

    // Whether a hover at `point`, in scene coordinates, moves the selection.
    function hoverTakes(point) {
        if (state.armed) return true;
        const moved = Logic.pointerMoved(state.last, point);
        state.last = Qt.point(point.x, point.y);
        if (moved) state.armed = true;
        return moved;
    }

    function disarm() {
        state.armed = false;
        state.last = null;
    }

    // The next hover moves the selection without the pointer moving first,
    // as after a click that rebuilt the list under the pointer.
    function arm() { state.armed = true; }

    // The place, 0 first, of a row that arrives among the others that
    // arrive in the same turn.
    function enterSlot() {
        if (state.arrivals === 0) Qt.callLater(state.endArrivals);
        return state.arrivals++;
    }

    QtObject {
        id: state

        property Item target: null
        property bool snapping: false
        property bool armed: false
        // The last scene point a hover read since the cursor was disarmed.
        property var last: null
        property int arrivals: 0

        function settle() { snapping = false; }
        function endArrivals() { arrivals = 0; }
    }

    // `row` and every item between it and the cursor's parent, whose
    // positions sum to the row's place; empty while the row or the cursor
    // has no parent yet, as while a view creates it, and null for a row
    // outside the cursor's parent.
    function chainOf(row) {
        if (row.parent === null || root.parent === null) return [];
        const out = [];
        for (let at = row; at !== root.parent; at = at.parent) {
            if (at === null) return null;
            out.push(at);
        }
        return out;
    }
    readonly property var chain: state.target === null ? [] : chainOf(state.target) ?? []
    onChainChanged: place()

    Instantiator {
        model: root.chain
        delegate: Connections {
            required property Item modelData
            target: modelData
            // A surface destroys the cursor, and this delegate, before
            // the rows it follows, and a row can still move after they went.
            function onXChanged() { if (root !== null) root.place(); }
            function onYChanged() { if (root !== null) root.place(); }
            function onWidthChanged() { if (root !== null) root.place(); }
            function onHeightChanged() { if (root !== null) root.place(); }
        }
    }

    function place() {
        const chain = root.chain;
        if (chain.length === 0) return;
        let x = 0, y = 0;
        for (const at of chain) {
            x += at.x;
            y += at.y;
        }
        root.x = x;
        root.width = chain[0].width;
        move(travel, "y", y, root.motion.travel.duration);
        move(resize, "height", chain[0].height, root.motion.resize.duration);
    }

    // Glide `property` to `value` over `animation`, or land at once while
    // snapping, hidden or stilled.
    function move(animation, property, value, duration) {
        const glide = !state.snapping && root.shown && root.opacity > 0 && duration > 0;
        if (glide && animation.running && animation.to === value) return;
        animation.stop();
        if (glide && root[property] !== value) {
            animation.to = value;
            animation.start();
        } else root[property] = value;
    }

    ListAnimation { id: travel; target: root; property: "y"; step: root.motion.travel }
    ListAnimation { id: resize; target: root; property: "height"; step: root.motion.resize }

    function adopt() {
        if (background === null) return;
        background.parent = root;
        background.anchors.fill = root;
    }
    onBackgroundChanged: adopt()
    Component.onCompleted: adopt()
}
