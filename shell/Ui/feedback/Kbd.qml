import QtQuick
import qs.Commons
import qs.Ui

// A key cap: one key name in the kbd role inside a bordered chip
// `kbd.height` tall, never narrower than it is tall. Under a rounded theme
// the side padding grows until the label clears the drawn corner.
Rectangle {
    id: root

    property string text: ""
    readonly property real sidePadding: Inset.controlPadding(Theme.kbd.paddingX, Theme.kbd.radius, Theme.kbd.height, label.lineBox, Theme.space.xs)

    implicitWidth: Math.max(Theme.kbd.height, Math.round(label.opticalWidth + 2 * sidePadding))
    implicitHeight: Math.max(Theme.kbd.height, label.lineBox)
    radius: Theme.kbd.radius
    color: Theme.kbd.background
    border.width: Theme.kbd.border
    border.color: Theme.kbd.borderColor

    Label {
        id: label
        role: "kbd"
        text: root.text
        color: Theme.kbd.foreground
        x: Math.round((root.width - opticalWidth) / 2)
        y: topForCapCenter(root.height)
    }
}
