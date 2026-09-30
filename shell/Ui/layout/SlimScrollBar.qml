import QtQuick
import qs.Ui

// A slim scroll bar a list draws beside its own Flickable, for a plugin
// that owns its look (appearance.md): every value it draws with is an
// input, and it reads no theme token. It shows only while `flickable`
// overflows; its thumb is the view's share of the content, never shorter
// than `minLength`, and sits as far down the track as the view is down the
// content. The thumb is `thin` wide at rest and `wide` under the pointer or
// while dragged, at `idleOpacity` at rest, `movingOpacity` while the view
// moves and `activeOpacity` under the pointer. `widthStep` and
// `opacityStep` are `{ duration, easing, curve }` steps, as ListAnimation
// takes them. Dragging the thumb scrolls the view with it. The caller
// places the bar across and sets its width; its top is the flickable's.
Item {
    id: root

    required property Flickable flickable
    required property real thin
    required property real wide
    required property real minLength
    required property color color
    required property real radius
    required property real idleOpacity
    required property real movingOpacity
    required property real activeOpacity
    required property var widthStep
    required property var opacityStep

    readonly property real ratio: flickable.contentHeight <= 0 ? 1 : flickable.height / flickable.contentHeight
    readonly property real travel: Math.max(1, flickable.contentHeight - flickable.height)
    readonly property real progress: Math.max(0, Math.min(1, (flickable.contentY - flickable.originY) / travel))
    readonly property bool active: grip.containsMouse || grip.pressed

    visible: ratio < 1
    height: Math.max(minLength, flickable.height * ratio)
    y: (flickable.height - height) * progress

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.active ? root.wide : root.thin
        height: parent.height
        radius: root.radius
        color: root.color
        opacity: root.active ? root.activeOpacity : root.flickable.moving ? root.movingOpacity : root.idleOpacity
        Behavior on width { ListAnimation { step: root.widthStep } }
        Behavior on opacity { ListAnimation { step: root.opacityStep } }
    }

    // pointer-cursor-exempt: a scroll bar keeps the arrow, as Qt's own scroll bars do
    MouseArea {
        id: grip
        property real grab: 0
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: true
        onPressed: mouse => { grab = mouse.y; }
        onPositionChanged: mouse => {
            if (!pressed) return;
            const track = Math.max(1, root.flickable.height - root.height);
            const top = root.y + mouse.y - grab;
            root.flickable.contentY = root.flickable.originY + Math.max(0, Math.min(1, top / track)) * root.travel;
        }
    }
}
