import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// A tooltip for the item it is declared in: after the theme's delay with
// the pointer resting on the item it opens in its own surface under the
// item and takes no focus. It closes when the pointer leaves, on a press
// on the item, when the item hides, and it does not open while another
// overlay is open. The declaring item is an invisible, sizeless member of
// its parent.
Item {
    id: root

    property string text: ""
    readonly property bool opened: window.visible
    readonly property Item anchorItem: parent

    // The handlers live on the anchor, made once it is known: a handler
    // declared with a parent binding crashes the engine while the parent
    // is still null.
    property var hover: null
    property var press: null
    readonly property Component hoverComponent: Component { HoverHandler {} }
    // pointer-cursor-exempt: it watches a press on the anchor to close the tooltip; the anchor's own control owns the cursor
    readonly property Component pressComponent: Component { TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds } }
    readonly property bool resting: hover !== null && hover.hovered && !(press !== null && press.pressed)

    visible: false

    Component.onCompleted: {
        if (anchorItem === null) return;
        hover = hoverComponent.createObject(anchorItem);
        press = pressComponent.createObject(anchorItem);
    }

    onRestingChanged: {
        if (resting) delay.restart();
        else { delay.stop(); window.visible = false; }
    }

    Timer {
        id: delay
        interval: Theme.tooltip.delay
        onTriggered: if (root.resting && OverlayState.open === 0) window.visible = true
    }

    // Another overlay opening closes a tooltip already shown.
    Connections {
        target: OverlayState
        function onOpenChanged() { if (OverlayState.open > 0) window.visible = false; }
    }

    PopupWindow {
        id: window

        anchor.item: root.anchorItem
        anchor.edges: Edges.Bottom
        anchor.gravity: Edges.Bottom
        anchor.adjustment: PopupAdjustment.Flip | PopupAdjustment.Slide
        anchor.margins.bottom: -Theme.tooltip.gap
        grabFocus: false
        visible: false
        color: "transparent"
        implicitWidth: Math.max(1, label.implicitWidth + 2 * Theme.tooltip.paddingX)
        implicitHeight: Math.max(1, label.implicitHeight + 2 * Theme.tooltip.paddingY)

        Rectangle {
            anchors.fill: parent
            radius: Theme.tooltip.radius
            color: Theme.tooltip.background
        }

        Label {
            id: label
            role: "tooltip"
            text: root.text
            color: Theme.tooltip.foreground
            anchors.centerIn: parent
        }
    }

    readonly property AnchorTracker tracker: AnchorTracker { popup: window; anchor: root.anchorItem }
}
