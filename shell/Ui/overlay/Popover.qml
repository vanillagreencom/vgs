import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// A popup under the item it is declared in: its own surface anchored to
// that item, so it leaves a bar of any height; it takes keyboard focus
// while open, and closes on a press outside, on Escape, and when its
// anchor hides. It follows the anchor when that moves. Content goes in
// the body; `width` is the author's, the height follows the content. The
// declaring item is an invisible, sizeless member of its parent.
Item {
    id: root

    default property alias content: body.data
    readonly property bool opened: window.visible
    readonly property Item anchorItem: parent

    visible: false

    function open() {
        window.visible = true;
        scope.forceActiveFocus();
    }
    function close() { window.visible = false; }
    function toggle() { if (opened) close(); else open(); }

    PopupWindow {
        id: window

        anchor.item: root.anchorItem
        anchor.edges: Edges.Bottom | Edges.Left
        anchor.gravity: Edges.Bottom | Edges.Right
        anchor.adjustment: PopupAdjustment.Flip | PopupAdjustment.Slide
        anchor.margins.bottom: -Theme.popover.gap
        grabFocus: true
        visible: false
        color: "transparent"
        implicitWidth: Math.max(1, root.width > 0 ? root.width : body.childrenRect.width + 2 * Theme.popover.padding)
        implicitHeight: Math.max(1, body.childrenRect.height + 2 * Theme.popover.padding)
        onVisibleChanged: visible ? OverlayState.opened() : OverlayState.closed()

        FocusScope {
            id: scope
            anchors.fill: parent
            focus: true
            Keys.onEscapePressed: root.close()

            Rectangle {
                anchors.fill: parent
                radius: Theme.popover.radius
                color: Theme.popover.background
                border.width: Theme.border.thin
                border.color: Theme.popover.border
            }

            Item {
                id: body
                anchors.fill: parent
                anchors.margins: Theme.popover.padding
            }
        }
    }

    readonly property AnchorTracker tracker: AnchorTracker { popup: window; anchor: root.anchorItem }
}
