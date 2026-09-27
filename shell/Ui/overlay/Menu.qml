import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// A menu of MenuItem entries under the item it is declared in, in its own
// surface. Up and Down move the highlight, Enter triggers the highlighted
// entry, a click triggers an entry, and any trigger closes the menu; a
// press outside and Escape close it too. It follows its anchor when that
// moves and closes when it hides. The declaring item is an invisible,
// sizeless member of its parent.
Item {
    id: root

    default property alias entries: column.data
    readonly property bool opened: window.visible
    readonly property Item anchorItem: parent
    property int currentIndex: -1

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
        currentIndex = -1;
        window.visible = true;
        scope.forceActiveFocus();
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

    // The widest entry by its own content, before the column sets every
    // entry's width.
    readonly property real widest: {
        let width = 0;
        for (const item of items()) width = Math.max(width, item.implicitWidth);
        return width;
    }

    onCurrentIndexChanged: items().forEach((item, index) => { item.highlighted = index === currentIndex; })

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
        implicitWidth: Math.max(Theme.menu.minWidth, root.widest + 2 * Theme.menu.padding)
        implicitHeight: Math.max(1, column.implicitHeight + 2 * Theme.menu.padding)
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

            Rectangle {
                anchors.fill: parent
                radius: Theme.menu.radius
                color: Theme.menu.background
                border.width: Theme.border.thin
                border.color: Theme.menu.border
            }

            Column {
                id: column
                x: Theme.menu.padding
                y: Theme.menu.padding
                width: parent.width - 2 * Theme.menu.padding
            }
        }
    }

    readonly property AnchorTracker tracker: AnchorTracker { popup: window; anchor: root.anchorItem }
}
