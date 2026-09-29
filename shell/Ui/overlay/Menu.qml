import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// A menu of MenuItem entries under the item it is declared in, in its own
// surface. Up and Down move the highlight, Enter triggers the highlighted
// entry, a click triggers an entry, and any trigger closes the menu; a
// press outside and Escape close it too. Typing letters highlights the
// first reachable entry whose text starts with them, the letters kept for
// `menu.typeahead` milliseconds. Entries taller than `maxHeight` scroll
// inside the menu, and the highlighted entry is kept in view; opening
// shows the top and highlights the first checked entry, in view. It follows its anchor when that
// moves and closes when it hides. The declaring item is an invisible,
// sizeless member of its parent.
Item {
    id: root

    default property alias entries: column.data
    readonly property bool opened: window.visible
    readonly property Item anchorItem: parent
    property int currentIndex: -1
    // The height the entries take before the menu scrolls.
    property real maxHeight: Theme.menu.maxHeight
    // The letters typed so far toward an entry, cleared after
    // `menu.typeahead` milliseconds without one.
    property string typed: ""
    readonly property alias scrollArea: scroll

    visible: false

    property bool counted: false
    function share(open) {
        if (open === counted) return;
        counted = open;
        if (open) OverlayState.opened(); else OverlayState.closed();
    }
    Component.onDestruction: share(false)

    // The MenuItem children of the column, in order, and the ones the
    // keyboard may reach: enabled and shown.
    function items() { return column.children.filter(child => child.triggered !== undefined); }
    function reachable(item) { return item.enabled && item.visible; }

    function open() {
        typed = "";
        currentIndex = items().findIndex(item => reachable(item) && item.checked);
        window.visible = true;
        scope.forceActiveFocus();
        scroll.contentY = 0;
        reveal();
    }
    function close() { window.visible = false; }
    function toggle() { if (opened) close(); else open(); }

    // Move the highlight by `step` over the reachable entries: from none,
    // Down takes the first and Up the last.
    function move(step) {
        const all = items();
        const reach = all.map((item, index) => reachable(item) ? index : -1).filter(index => index !== -1);
        if (reach.length === 0) return;
        const at = reach.indexOf(currentIndex);
        if (at === -1) { currentIndex = step > 0 ? reach[0] : reach[reach.length - 1]; return; }
        currentIndex = reach[(at + step + reach.length) % reach.length];
    }

    function triggerCurrent() {
        const all = items();
        if (currentIndex >= 0 && currentIndex < all.length && reachable(all[currentIndex])) all[currentIndex].triggered();
    }

    // Add `letter` to the typed letters and highlight the first reachable
    // entry whose text starts with them; when none does, start again from
    // `letter` alone. Answers whether an entry matched.
    function typeAhead(letter) {
        const all = items();
        const find = prefix => all.findIndex(item => reachable(item) && String(item.text).toLowerCase().indexOf(prefix) === 0);
        let wanted = typed + letter.toLowerCase();
        let found = find(wanted);
        if (found === -1) {
            wanted = letter.toLowerCase();
            found = find(wanted);
        }
        typed = wanted;
        typing.restart();
        if (found !== -1) currentIndex = found;
        return found !== -1;
    }

    // Scroll the highlighted entry into view.
    function reveal() {
        const all = items();
        if (currentIndex < 0 || currentIndex >= all.length) return;
        const item = all[currentIndex];
        if (item.y < scroll.contentY) scroll.contentY = item.y;
        else if (item.y + item.height > scroll.contentY + scroll.height) scroll.contentY = item.y + item.height - scroll.height;
    }

    // The widest entry by its own content, before the column sets every
    // entry's width.
    readonly property real widest: {
        let width = 0;
        for (const item of items()) width = Math.max(width, item.implicitWidth);
        return width;
    }

    onCurrentIndexChanged: {
        items().forEach((item, index) => { item.highlighted = index === currentIndex; });
        reveal();
    }

    Timer { id: typing; interval: Theme.menu.typeahead; onTriggered: root.typed = "" }

    // Every entry's trigger closes the menu, by click or by key.
    readonly property Instantiator closers: Instantiator {
        model: root.opened ? root.items() : []
        delegate: Connections {
            required property var modelData
            target: modelData
            function onTriggered() { root.close(); }
        }
    }

    PopupWindow {
        id: window

        anchor.item: root.anchorItem
        anchor.edges: Edges.Bottom | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Right
        anchor.adjustment: PopupAdjustment.Flip | PopupAdjustment.Slide
        anchor.margins.bottom: -Theme.menu.gap
        grabFocus: true
        visible: false
        color: "transparent"
        implicitWidth: Math.max(Theme.menu.minWidth, root.widest + 2 * Theme.menu.padding + (scroll.overflowing ? Theme.scrollArea.gutter : 0))
        implicitHeight: Math.max(1, Math.min(column.implicitHeight, root.maxHeight) + 2 * Theme.menu.padding)
        onVisibleChanged: root.share(visible)

        FocusScope {
            id: scope
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: root.close()
            Keys.onUpPressed: root.move(-1)
            Keys.onDownPressed: root.move(1)
            Keys.onReturnPressed: root.triggerCurrent()
            Keys.onEnterPressed: root.triggerCurrent()
            // A printable letter without a modifier jumps; every other key
            // goes on to the handlers above.
            Keys.onPressed: event => {
                const code = event.text.length === 1 ? event.text.charCodeAt(0) : 0;
                const plain = !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier));
                event.accepted = code > 32 && code !== 127 && plain ? root.typeAhead(event.text) : false;
            }

            Rectangle {
                anchors.fill: parent
                radius: Theme.menu.radius
                color: Theme.menu.background
                border.width: Theme.border.thin
                border.color: Theme.menu.border
            }

            ScrollArea {
                id: scroll
                x: Theme.menu.padding
                y: Theme.menu.padding
                width: parent.width - 2 * Theme.menu.padding
                height: parent.height - 2 * Theme.menu.padding

                Column {
                    id: column
                    width: scroll.contentWidth
                }
            }
        }
    }

    readonly property AnchorTracker tracker: AnchorTracker { popup: window; anchor: root.anchorItem }
}
