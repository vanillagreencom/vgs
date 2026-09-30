import QtQuick
import qs.Ui

// A compact text button on the glass: quiet at rest, a plate on hover, a
// squish while pressed. `emphasized` lifts it a step at rest.
Item {
    id: pill

    required property var look
    property string text: ""
    property bool emphasized: false
    readonly property bool hovered: mouse.containsMouse
    signal clicked()

    implicitWidth: label.implicitWidth + 2 * look.pill.padX
    implicitHeight: look.pill.height

    Rectangle {
        anchors.fill: parent
        radius: pill.look.radius.full
        scale: mouse.pressed ? pill.look.pill.pressScale : 1
        color: mouse.pressed ? pill.look.pill.pressed : (pill.hovered ? pill.look.pill.hover : (pill.emphasized ? pill.look.pill.emphasized : pill.look.pill.rest))
        border.width: pill.look.pill.borderWidth
        border.color: pill.hovered ? pill.look.pill.border : pill.look.pill.borderRest
        Behavior on color { ColorAnim { duration: pill.look.motion.duration.medium2; curve: pill.look.motion.curve.standard } }
        Behavior on scale { Anim { duration: pill.look.motion.duration.short4; curve: pill.look.motion.curve.emphasizedDecel } }
    }

    Text {
        id: label
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: pill.text
        color: pill.look.text.foreground
        opacity: pill.hovered || pill.emphasized ? 1 : pill.look.pill.idle
        font.family: pill.look.font.family
        font.pixelSize: pill.look.text.label.size
        font.weight: pill.look.text.label.weight
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        PointerCursor {}
        onClicked: pill.clicked()
    }
}
