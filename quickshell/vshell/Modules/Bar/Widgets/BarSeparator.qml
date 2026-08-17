import QtQuick
import qs.Common

Item {
    id: root

    property bool barIsVertical: false
    property real barThickness: 48

    width: barIsVertical ? barThickness : 1
    height: barIsVertical ? 1 : barThickness
    implicitWidth: width
    implicitHeight: height

    Rectangle {
        width: root.barIsVertical ? parent.width * 0.6 : 1
        height: root.barIsVertical ? 1 : parent.height * 0.6
        anchors.centerIn: parent
        color: Theme.outline
        opacity: 0.3
    }
}
