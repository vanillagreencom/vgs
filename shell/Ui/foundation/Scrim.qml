import QtQuick
import qs.Commons

// A wash over everything behind a modal surface: it fills its parent with
// `color.scrim`, takes the presses, the hover and the wheel that land on it,
// so nothing under it answers, and emits `clicked` for a click-away. The caller declares the
// modal surface after it, so the surface sits above the scrim.
Rectangle {
    id: root

    signal clicked()

    anchors.fill: parent
    color: Theme.color.scrim

    // pointer-cursor-exempt: a press here is a click away from the modal surface, not a control
    MouseArea {
        anchors.fill: root
        // A MouseArea passes hover, and a wheel no handler accepts, to the
        // items under it.
        hoverEnabled: true
        onClicked: root.clicked()
        onWheel: wheel => { wheel.accepted = true; }
    }
}
