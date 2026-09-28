import QtQuick

// The selection plate: a soft lifted plate with a hairline and a faint
// top sheen, gliding between rows as one item rather than lighting each.
Rectangle {
    id: plate

    required property var look
    property bool shown: true

    radius: look.radius.md
    opacity: shown ? 1 : 0
    color: look.highlight.plate
    border.width: look.highlight.borderWidth
    border.color: look.highlight.border

    Behavior on opacity {
        Anim { duration: plate.look.motion.duration.short4; curve: plate.look.motion.curve.standard }
    }

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
