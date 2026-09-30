import QtQuick

// The selection plate: a soft lifted plate with a hairline and a faint
// top sheen, the launcher's own look for the ListCursor that glides it
// between rows and fades it.
Rectangle {
    id: plate

    required property var look

    radius: look.radius.md
    color: look.highlight.plate
    border.width: look.highlight.borderWidth
    border.color: look.highlight.border

    Rectangle {
        anchors.fill: parent
        anchors.margins: plate.border.width
        radius: Math.max(0, plate.radius - plate.look.highlight.borderWidth)
        gradient: Gradient {
            GradientStop { position: 0; color: plate.look.highlight.sheen }
            GradientStop { position: plate.look.highlight.sheenStop; color: plate.look.highlight.sheenEnd }
        }
    }
}
