import QtQuick
import qs.Commons

// An on and off switch drawn from the theme tokens.
Rectangle {
    id: root

    property bool on: false
    signal clicked()

    implicitWidth: Theme.space.xxxl + Theme.space.xs
    implicitHeight: Theme.space.xl + Theme.space.xxs
    radius: Theme.radius.full
    color: on ? Theme.color.accent : Theme.color.borderStrong

    // The knob sits `inset` inside the track on every side.
    readonly property int inset: Theme.space.xxs

    Rectangle {
        width: parent.height - 2 * root.inset
        height: width
        radius: Theme.radius.full
        y: root.inset
        x: root.on ? parent.width - width - root.inset : root.inset
        color: Theme.color.background
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.clicked()
    }
}
