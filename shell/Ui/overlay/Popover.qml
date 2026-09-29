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
    readonly property real availableHeight: screenHeight()

    visible: false

    // The overlay's share of OverlayState, taken once while open and given
    // back once on close or on destruction, whichever comes first.
    property bool counted: false
    function share(open) {
        if (open === counted) return;
        counted = open;
        if (open) OverlayState.opened(); else OverlayState.closed();
    }
    Component.onDestruction: share(false)

    function open() {
        window.visible = true;
        scope.forceActiveFocus();
    }
    function close() { window.visible = false; }
    function toggle() { if (opened) close(); else open(); }
    function screenHeight() {
        if (anchorItem === null || anchorItem === undefined) return 0;
        const window = anchorItem.Window.window;
        if (window === null || window === undefined || window.screen === null || window.screen === undefined) return 0;
        return window.screen.height;
    }

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
        implicitWidth: Math.max(1, root.width > 0 ? root.width : pane.implicitWidth)
        implicitHeight: Math.max(1, pane.implicitHeight)
        onVisibleChanged: root.share(visible)

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

            Pane {
                id: pane
                anchors.fill: parent
                container: "popover"
                fitToContent: true
                maximumHeight: root.availableHeight > 0 ? root.availableHeight * Theme.popover.maxHeightShare : Theme.size.panel.maxHeight
                gap: Theme.popover.gap
                bodySpacing: Theme.popover.gap

                Column {
                    id: body
                    width: parent.width
                    spacing: Theme.popover.gap
                }
            }
        }
    }

    readonly property AnchorTracker tracker: AnchorTracker { popup: window; anchor: root.anchorItem }
}
