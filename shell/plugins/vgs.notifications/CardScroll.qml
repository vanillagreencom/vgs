import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Shared scroll frame for notification cards. The stack and the panel use
// the same text column, overflow rule and slim bar.
Item {
    id: root

    required property var look
    property real maxHeight: 0
    property string scrollObjectName: "notificationScrollBar"
    default property alias content: cards.data
    readonly property real textColumn: Math.ceil(Inset.clearing(look.card.pad, look.radius.full, look.card.width, look.card.maxHeight, look.radius.clearance, look.card.pad))
    readonly property alias flickable: view
    readonly property alias cards: cards

    implicitWidth: cards.implicitWidth + look.stack.pad * 2
    implicitHeight: Math.min(cards.implicitHeight + look.stack.tail, maxHeight)

    function motionStep(duration, curve) {
        return { duration: duration, easing: Easing.BezierSpline, curve: [curve.x1, curve.y1, curve.x2, curve.y2, 1, 1] };
    }

    Flickable {
        id: view
        anchors.fill: parent
        contentWidth: width
        contentHeight: cards.implicitHeight + root.look.stack.tail
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        clip: true

        ColumnLayout {
            id: cards
            x: root.look.stack.pad
            width: root.look.card.width
            spacing: 0
        }
    }

    SlimScrollBar {
        id: scrollbar
        objectName: root.scrollObjectName
        parent: view
        flickable: view
        x: cards.x + cards.width + root.look.scrollbar.gap
        width: root.look.scrollbar.width
        thin: root.look.scrollbar.thin
        wide: root.look.scrollbar.wide
        minLength: root.look.scrollbar.minHeight
        color: root.look.text.foreground
        radius: root.look.radius.full
        idleOpacity: root.look.scrollbar.idle
        movingOpacity: root.look.scrollbar.moving
        activeOpacity: root.look.scrollbar.active
        widthStep: root.motionStep(root.look.motion.duration.short4, root.look.motion.curve.standard)
        opacityStep: root.motionStep(root.look.motion.duration.medium2, root.look.motion.curve.standard)
    }
}
