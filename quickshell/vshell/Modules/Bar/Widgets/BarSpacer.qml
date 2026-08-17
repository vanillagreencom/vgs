import QtQuick
import qs.Common

Item {
    id: root

    property bool barIsVertical: false
    property real widgetThickness: 30
    property int spacerSize: 20

    width: barIsVertical ? widgetThickness : spacerSize
    height: barIsVertical ? spacerSize : widgetThickness
    implicitWidth: width
    implicitHeight: height

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.color: Theme.outlineStrong
        border.width: 1
        radius: 2
        visible: false

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            propagateComposedEvents: true
            cursorShape: Qt.ArrowCursor
            onEntered: parent.visible = true
            onExited: parent.visible = false
        }
    }
}
