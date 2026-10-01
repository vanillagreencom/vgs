import QtQuick
import qs.Commons
import "KeyNavLogic.js" as Logic

// Shared keyboard navigator for a composite control. The owner keeps the
// selected index in `currentIndex`, passes reachability and labels through
// callbacks, calls `handle(event)` from `Keys.onPressed`, and writes its
// own index in `onMoved`. The navigator owns key-to-intent mapping,
// roving movement, page movement, type-ahead buffering, optional cursor
// disarming and optional reveal into a flickable.
Item {
    id: root

    visible: false
    width: 0
    height: 0

    // Number of rows or entries in the composite.
    property int count: 0
    // The owner's current row or entry index.
    property int currentIndex: -1
    // `vertical`, `horizontal` or `both` for arrow intent.
    property string orientation: "vertical"
    // Whether movement wraps at the ends.
    property bool wrap: true
    // Whether a text field currently owns caret keys.
    property bool textEntry: false
    // Whether Space activates the current entry. A searchable owner can let
    // Space fall through to its filter while Enter still activates.
    property bool spaceActivates: true
    // Whether Left and Right cross to choices inside the current vertical row.
    property bool crossAxis: false
    // Rows moved by PageUp and PageDown.
    property int pageSize: 0
    // Optional viewport height for deriving a page size.
    property real viewHeight: 0
    // Optional row height for deriving a page size.
    property real rowHeight: 0
    // Optional callback: `reachable(index)`.
    property var reachable: null
    // Optional callback: `labelAt(index)` for type-ahead.
    property var labelAt: null
    // Optional ListCursor; `disarm()` runs before a key move.
    property var cursor: null
    // Optional Flickable to reveal a moved-to item.
    property var flickable: null
    // Optional callback: `itemAt(index)` for reveal.
    property var itemAt: null
    // The active type-ahead buffer.
    property string typed: ""
    // Milliseconds before type-ahead starts again.
    property int typeAheadDelay: Theme.menu.typeahead

    // Emitted when the owner must move its selected index.
    signal moved(int index)
    // Emitted when activation should run for `index`.
    signal activated(int index)
    // Emitted when the selected item should be removed.
    signal removed(int index)
    // Emitted when the selected item's context menu should open.
    signal menuRequested(int index)
    // Emitted when a tabbed owner should step by `delta`.
    signal tabStepped(int delta)
    // Emitted when a row with horizontal choices should step by `delta`.
    signal crossed(int delta)

    property Timer typing: Timer { interval: root.typeAheadDelay; onTriggered: root.typed = "" }

    // Whether index is reachable.
    function canReach(index) {
        return reachable === null || reachable === undefined ? true : reachable(index);
    }

    // Label used by type-ahead at index.
    function label(index) {
        return labelAt === null || labelAt === undefined ? "" : labelAt(index);
    }

    // Move by a signed delta through the roving list.
    function moveBy(delta) {
        return moveTo(Logic.step(currentIndex, count, delta, wrap, canReach));
    }

    // Move to the first reachable item.
    function first() {
        return moveTo(Logic.edge(count, canReach, false));
    }

    // Move to the last reachable item.
    function last() {
        return moveTo(Logic.edge(count, canReach, true));
    }

    // Move by one page.
    function pageBy(delta) {
        const rows = pageSize > 0 ? pageSize : Logic.pageRows(viewHeight, rowHeight);
        return moveTo(Logic.step(currentIndex, count, delta * rows, false, canReach));
    }

    // Extend the type-ahead buffer by `letter` and move to the match.
    function typeAhead(letter) {
        if (labelAt === null || labelAt === undefined) return false;
        const labels = [];
        for (let i = 0; i < count; i++) labels.push(label(i));
        const result = Logic.typeAhead(typed, letter, labels, canReach, currentIndex);
        typed = result.typed;
        typing.restart();
        return moveTo(result.index);
    }

    // Move to an exact index and reveal it when configured.
    function moveTo(index) {
        if (index < 0 || index >= count || !canReach(index)) return false;
        if (cursor !== null && cursor !== undefined && cursor.disarm !== undefined) cursor.disarm();
        moved(index);
        reveal(index);
        return true;
    }

    // Reveal an index in the configured flickable.
    function reveal(index) {
        if (flickable === null || flickable === undefined || itemAt === null || itemAt === undefined) return;
        const item = itemAt(index);
        if (item === null || item === undefined) return;
        flickable.contentY = Logic.revealY(item.y, item.height, flickable.contentY, flickable.height, 0);
    }

    // Handle one QML key event and return whether the owner should accept it.
    function handle(event) {
        const action = Logic.intent(event.key, event.modifiers, orientation, textEntry, { spaceActivates, crossAxis });
        if (action === "prev") return moveBy(-1);
        else if (action === "next") return moveBy(1);
        else if (action === "first") return first();
        else if (action === "last") return last();
        else if (action === "pagePrev") return pageBy(-1);
        else if (action === "pageNext") return pageBy(1);
        else if (action === "activate") {
            if (currentIndex >= 0 && currentIndex < count && canReach(currentIndex)) {
                activated(currentIndex);
                return true;
            }
            return false;
        } else if (action === "remove") {
            if (currentIndex >= 0 && currentIndex < count && canReach(currentIndex)) {
                removed(currentIndex);
                return true;
            }
            return false;
        } else if (action === "menu") {
            if (currentIndex >= 0 && currentIndex < count && canReach(currentIndex)) {
                menuRequested(currentIndex);
                return true;
            }
            return false;
        } else if (action === "tabPrev" || action === "tabNext") {
            tabStepped(action === "tabPrev" ? -1 : 1);
            return true;
        } else if (action === "crossPrev" || action === "crossNext") {
            if (currentIndex >= 0 && currentIndex < count && canReach(currentIndex)) {
                crossed(action === "crossPrev" ? -1 : 1);
                return true;
            }
            return false;
        } else {
            const letter = Logic.printable(event.text, event.modifiers);
            return letter !== "" ? typeAhead(letter) : false;
        }
    }
}
