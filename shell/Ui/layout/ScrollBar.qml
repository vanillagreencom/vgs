import QtQuick
import qs.Commons

// The embedded vertical bar of a Flickable, internal to the module: the
// bar ScrollArea, Menu and Select draw. It stands `scrollArea.barInset` in
// from the flickable's right edge, inside the gutter the content leaves
// free, and shows only while the content overflows. It is at full opacity
// while `hovered` holds, a thumb is pressed or the content moves, and fades
// to `scrollArea.idleOpacity` `scrollArea.fadeDelay` milliseconds after.
// Dragging the thumb scrolls the content with it; a press on the track
// above or below the thumb pages one view up or down. The thumb is never
// shorter than `scrollArea.minThumb`.
Item {
    id: root

    // The flickable the bar scrolls; the bar is its child.
    required property Flickable flickable
    // Whether the pointer rests on what the bar scrolls; the owner sets it.
    property bool hovered: false

    readonly property real maxY: Math.max(0, flickable.contentHeight - flickable.height)
    // Content past the view by less than half a pixel is the float noise
    // of a layout that fits its view exactly, never an overflow to scroll.
    readonly property bool needed: maxY >= 0.5
    readonly property real thumbLength: needed ? Math.min(height, Math.max(Theme.scrollArea.minThumb, height * flickable.height / flickable.contentHeight)) : height
    readonly property real travel: height - thumbLength
    readonly property bool active: hovered || barHover.hovered || thumbArea.pressed || flickable.moving || recent.running
    readonly property alias thumb: thumbItem

    parent: flickable
    x: flickable.width - width - Theme.scrollArea.barInset
    y: 0
    z: 1
    width: Theme.scrollArea.barWidth
    height: flickable.height
    visible: needed
    opacity: active ? 1 : Theme.scrollArea.idleOpacity
    Behavior on opacity { NumberAnimation { duration: Theme.scrollArea.fade; easing.type: Theme.motion.easing.standard } }

    // Move the content to `y`, held inside it.
    function scrollTo(y) { flickable.contentY = Math.max(0, Math.min(maxY, y)); }
    // One view up for a negative `direction`, down for a positive one.
    function page(direction) { scrollTo(flickable.contentY + (direction < 0 ? -1 : 1) * flickable.height); }
    // Put the thumb's top at `top` on the track, the content following it.
    function dragTo(top) { if (travel > 0) scrollTo(Math.max(0, Math.min(travel, top)) / travel * maxY); }

    Connections {
        target: root.flickable
        function onContentYChanged() { recent.restart(); }
    }
    Timer { id: recent; interval: Theme.scrollArea.fadeDelay }

    HoverHandler { id: barHover }

    // pointer-cursor-exempt: a scroll bar keeps the arrow, as Qt's own scroll bars do
    // keyboard-path: ScrollArea owns PageUp, PageDown, Home and End for keyboard scrolling
    MouseArea {
        id: track
        anchors.fill: parent
        onPressed: mouse => root.page(mouse.y < thumbItem.y ? -1 : 1)
    }

    Rectangle {
        id: thumbItem
        width: parent.width
        height: root.thumbLength
        y: root.maxY > 0 ? root.travel * root.flickable.contentY / root.maxY : 0
        radius: Theme.scrollArea.barRadius
        color: thumbArea.pressed || thumbHover.hovered ? Theme.scrollArea.barHover : Theme.scrollArea.bar

        HoverHandler { id: thumbHover }

        // pointer-cursor-exempt: a scroll bar keeps the arrow, as Qt's own scroll bars do
        // keyboard-path: ScrollArea owns PageUp, PageDown, Home and End for keyboard scrolling
        MouseArea {
            id: thumbArea
            // Where on the thumb the press landed, so the thumb keeps it
            // under the pointer while dragged.
            property real grab: 0
            anchors.fill: parent
            preventStealing: true
            onPressed: mouse => { grab = mouse.y; }
            onPositionChanged: mouse => { if (pressed) root.dragTo(mapToItem(root, 0, mouse.y).y - grab); }
        }
    }
}
