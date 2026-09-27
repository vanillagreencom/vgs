import QtQuick
import qs.Commons

// The ring a control draws while it has keyboard focus. It sits inside the
// control's background, filling it, and shows for `visualFocus`, which Qt
// raises for keyboard focus and not for a click, so a pointer user never
// sees it. `offset` is how far outside the background the ring sits.
Rectangle {
    id: root

    required property Item target
    property int offset: Theme.focusRing.offset

    anchors.fill: parent
    anchors.margins: -offset
    visible: target.visualFocus
    color: "transparent"
    border.color: Theme.focusRing.color
    border.width: Theme.focusRing.width
    radius: Theme.focusRing.radius + offset
}
