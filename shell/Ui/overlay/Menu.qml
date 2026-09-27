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

    // The MenuItem children of the column, in order.
    function items() { return column.children.filter(child => child.triggered !== undefined); }

    function open() {
        currentIndex = -1;
        window.visible = true;
        scope.forceActiveFocus();
    }
    function close() { window.visible = false; }
    function toggle() { if (opened) close(); else open(); }

    function move(step) {
        const all = items();
        if (all.length === 0) return;
        currentIndex = (currentIndex + step + all.length) % all.length;
    }

    function triggerCurrent() {
        const all = items();
        if (currentIndex >= 0 && currentIndex < all.length) all[currentIndex].triggered();
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
        implicitWidth: Math.max(Theme.menu.minWidth, column.childrenRect.width + 2 * Theme.menu.padding)
        implicitHeight: Math.max(1, column.implicitHeight + 2 * Theme.menu.padding)
        onVisibleChanged: visible ? OverlayState.opened() : OverlayState.closed()

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
