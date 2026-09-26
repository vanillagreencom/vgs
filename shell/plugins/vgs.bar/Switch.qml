import QtQuick
import qs.Commons

// An on and off switch drawn from the theme tokens.
Rectangle {
    id: root

    property bool on: false
    signal clicked()

    implicitWidth: Style.space(9)
    implicitHeight: Style.space(4.5)
    radius: height / 2
    color: on ? Color.accent : Color.muted

    // The knob sits `inset` inside the track on every side.
    readonly property int inset: Style.space(0.5)

    Rectangle {
        width: parent.height - 2 * root.inset
        height: width
        radius: width / 2
        y: root.inset
        x: root.on ? parent.width - width - root.inset : root.inset
        color: Color.background
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.clicked()
    }
}
