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

    Rectangle {
        width: parent.height - 4
        height: width
        radius: width / 2
        y: 2
        x: root.on ? parent.width - width - 2 : 2
        color: Color.background
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.clicked()
    }
}
