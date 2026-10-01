import QtQuick
import QtQuick.Templates as T
import qs.Ui
import qs.Ui as Ui

// An on and off switch on the glass: a translucent track that fills with
// the theme's accent while on, and a white knob with a soft shadow.
T.Switch {
    id: control

    required property var look
    property bool focusPreview: false

    implicitWidth: look.toggle.width
    implicitHeight: Math.max(look.toggle.height, look.toggle.hitHeight)
    hoverEnabled: true
    PointerCursor {}
    Accessible.name: text
    Keys.onReturnPressed: Ui.KeyNavLogic.activate(control)
    Keys.onEnterPressed: Ui.KeyNavLogic.activate(control)

    indicator: Item {
        implicitWidth: control.look.toggle.width
        implicitHeight: Math.max(control.look.toggle.height, control.look.toggle.hitHeight)

        Rectangle {
            id: track
            anchors.centerIn: parent
            width: control.look.toggle.width
            height: control.look.toggle.height
            radius: control.look.radius.full
            color: control.look.toggle.track
            border.width: control.look.toggle.borderWidth
            border.color: control.look.toggle.border

            Rectangle {
                anchors.fill: parent
                radius: control.look.radius.full
                color: control.look.palette.accent
                opacity: control.checked ? 1 : 0
                Behavior on opacity { Anim { duration: control.look.motion.duration.medium1; curve: control.look.motion.curve.emphasizedDecel } }
            }

            Rectangle {
                readonly property real inset: control.look.toggle.inset
                width: track.height - inset * 2
                height: width
                radius: control.look.radius.full
                x: inset + control.visualPosition * (track.width - width - inset * 2)
                y: inset
                color: control.look.toggle.knob
                scale: control.down ? control.look.toggle.pressScale : 1
                Behavior on x { Anim { duration: control.look.motion.duration.medium1; curve: control.look.motion.curve.emphasizedDecel } }
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
        }

        FocusRing { target: control }
    }

    contentItem: Item {}
}
