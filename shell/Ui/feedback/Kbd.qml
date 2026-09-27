import QtQuick
import qs.Commons
import qs.Ui

// A key cap: one key name in the code role inside a bordered chip.
Rectangle {
    id: root

    property string text: ""

    implicitWidth: label.implicitWidth + 2 * Theme.kbd.paddingX
    implicitHeight: label.implicitHeight + 2 * Theme.kbd.paddingX
    radius: Theme.kbd.radius
    color: Theme.kbd.background
    border.width: Theme.kbd.border
    border.color: Theme.kbd.borderColor

    Label {
        id: label
        role: "code"
        text: root.text
        color: Theme.kbd.foreground
        anchors.centerIn: parent
    }
}
