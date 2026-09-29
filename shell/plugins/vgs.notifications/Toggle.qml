import QtQuick
import qs.Ui

// An on and off switch on the glass: a translucent track that fills with
// the theme's accent while on, and a white knob with a soft shadow.
Item {
    id: control

    required property var look
    property bool checked: false
    signal toggled(bool checked)

    implicitWidth: look.toggle.width
    implicitHeight: look.toggle.height

    property real position: checked ? 1 : 0
    Behavior on position { Anim { duration: control.look.motion.duration.medium1; curve: control.look.motion.curve.emphasizedDecel } }

    Rectangle {
        anchors.fill: parent
        radius: control.look.radius.full
        color: control.look.toggle.track
        border.width: control.look.toggle.borderWidth
        border.color: control.look.toggle.border

        // The accent over the track, as much as the switch is on.
        Rectangle {
            anchors.fill: parent
            radius: control.look.radius.full
            color: control.look.palette.accent
            opacity: control.position
        }
    }

    Rectangle {
        readonly property real inset: control.look.toggle.inset
        width: parent.height - inset * 2
        height: width
        radius: control.look.radius.full
        x: inset + (parent.width - width - inset * 2) * control.position
        y: inset
        color: control.look.toggle.knob
        scale: mouse.pressed ? control.look.toggle.pressScale : 1
        Behavior on scale { Anim { duration: control.look.motion.duration.short4; curve: control.look.motion.curve.standard } }

        Rectangle {
            z: -1
            anchors.centerIn: parent
            anchors.verticalCenterOffset: control.look.toggle.knobShadowDrop
            width: parent.width + control.look.toggle.knobShadowGrow
            height: width
            radius: control.look.radius.full
            color: control.look.toggle.knobShadow
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        PointerCursor {}
        onClicked: control.toggled(!control.checked)
    }
}
