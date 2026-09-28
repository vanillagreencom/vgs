import QtQuick

// A round ghost button: a hover plate, a press squish and a pointer cursor.
Item {
    id: button

    required property var look
    property bool checked: false
    readonly property bool hovered: mouse.containsMouse
    default property alias content: inner.data
    signal clicked()

    width: look.button.size
    height: look.button.size

    Rectangle {
        anchors.fill: parent
        radius: button.look.radius.full
        color: mouse.pressed ? button.look.button.pressed : (button.hovered ? button.look.button.hover : (button.checked ? button.look.button.checked : button.look.button.rest))
        border.width: button.look.button.borderWidth
        border.color: button.hovered || button.checked ? button.look.button.border : button.look.button.borderRest
        Behavior on color {
            ColorAnim { duration: button.look.motion.duration.short4; curve: button.look.motion.curve.standard }
        }
        Behavior on border.color {
            ColorAnim { duration: button.look.motion.duration.short4; curve: button.look.motion.curve.standard }
        }
    }

    Item {
        id: inner
        anchors.fill: parent
        scale: mouse.pressed ? button.look.button.pressScale : 1
        Behavior on scale {
            Anim { duration: button.look.motion.duration.short4; curve: button.look.motion.curve.emphasizedDecel }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: button.clicked()
    }
}
