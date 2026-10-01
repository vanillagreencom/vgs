import QtQuick
import QtQuick.Templates as T
import qs.Ui
import qs.Ui as Ui

// A compact text button on the glass: quiet at rest, a plate on hover, a
// squish while pressed. `emphasized` lifts it a step at rest.
T.Button {
    id: pill

    required property var look
    property bool emphasized: false
    property bool focusPreview: false
    property bool tabFocusable: true

    implicitWidth: implicitContentWidth + 2 * look.pill.padX
    implicitHeight: look.pill.height
    focusPolicy: tabFocusable ? Qt.StrongFocus : Qt.NoFocus
    hoverEnabled: true
    PointerCursor {}
    Accessible.name: text
    Keys.onReturnPressed: Ui.KeyNavLogic.activate(pill)
    Keys.onEnterPressed: Ui.KeyNavLogic.activate(pill)

    contentItem: Text {
        id: label
        textFormat: Text.PlainText
        text: pill.text
        color: pill.look.text.foreground
        opacity: pill.hovered || pill.emphasized || pill.visualFocus || pill.focusPreview ? 1 : pill.look.pill.idle
        font.family: pill.look.font.family
        font.pixelSize: pill.look.text.label.size
        font.weight: pill.look.text.label.weight
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }

    background: Rectangle {
        radius: pill.look.radius.full
        scale: pill.down ? pill.look.pill.pressScale : 1
        color: pill.down ? pill.look.pill.pressed : (pill.hovered || pill.focusPreview ? pill.look.pill.hover : (pill.emphasized ? pill.look.pill.emphasized : pill.look.pill.rest))
        border.width: pill.look.pill.borderWidth
        border.color: pill.hovered || pill.visualFocus || pill.focusPreview ? pill.look.pill.border : pill.look.pill.borderRest
        Behavior on color { ColorAnim { duration: pill.look.motion.duration.medium2; curve: pill.look.motion.curve.standard } }
        Behavior on scale { Anim { duration: pill.look.motion.duration.short4; curve: pill.look.motion.curve.emphasizedDecel } }
        FocusRing { target: pill }
    }
}
