import QtQuick
import qs.Commons
import qs.Ui

// A key cap: one key name in the kbd role inside a bordered chip.
Rectangle {
    id: root

    property string text: ""

    implicitWidth: label.opticalWidth + 2 * Theme.kbd.paddingX
    implicitHeight: label.lineBox + 2 * Theme.kbd.paddingY
    radius: Theme.kbd.radius
    color: Theme.kbd.background
    border.width: Theme.kbd.border
    border.color: Theme.kbd.borderColor

    Label {
        id: label
        role: "kbd"
        text: root.text
        color: Theme.kbd.foreground
        x: Theme.kbd.paddingX
        y: topForCapCenter(root.height)
    }
}
