import QtQuick
import qs.Commons

// The ring a control draws while it has keyboard focus. It sits inside the
// control's background, filling it, and shows for `visualFocus`, which Qt
// raises for keyboard focus and not for a click, so a pointer user never
// sees it. A target without `visualFocus`, such as a text input, shows it
// for `activeFocus`, since an input with the caret is focused however it
// got there. `offset` is how far outside the background the ring sits.
// `targetRadius` is the corner of the shape the ring surrounds, so the
// ring follows a rounded control, a pill or a circle at its offset;
// `ringColor` lets a control keep a state cue, such as an error, while it
// holds focus.
Rectangle {
    id: root

    required property Item target
    property int offset: Theme.focusRing.offset
    property real targetRadius: Theme.focusRing.radius
    property color ringColor: Theme.focusRing.color
    // The ring's corner: the target's own, grown by the offset.
    readonly property real ringRadius: targetRadius + offset

    anchors.fill: parent
    anchors.margins: -offset
    visible: target.visualFocus === undefined ? target.activeFocus : target.visualFocus
    color: "transparent"
    border.color: ringColor
    border.width: Theme.focusRing.width
    radius: ringRadius
}
