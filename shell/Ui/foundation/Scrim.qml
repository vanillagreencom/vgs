import QtQuick
import qs.Commons

// A wash over everything behind a modal surface: it fills its parent with
// `color.scrim`, takes the presses that land on it, so nothing under it
// answers, and emits `clicked` for a click-away. The caller declares the
// modal surface after it, so the surface sits above the scrim.
Rectangle {
    id: root

    signal clicked()

    anchors.fill: parent
    color: Theme.color.scrim

    MouseArea {
        anchors.fill: root
        onClicked: root.clicked()
    }
}
