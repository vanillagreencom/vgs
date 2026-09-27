import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// A one-line text input. `leadingIcon` and `trailingIcon` name Lucide
// icons drawn inside the field; `actions` holds buttons drawn after the
// trailing icon, such as a clear or a submit button; `error` colours the
// outline with the error colour. The template owns the text, the cursor,
// the selection, `validator` and `acceptableInput`; the outline follows
// hover, focus and error, in that order of precedence reversed.
T.TextField {
    id: root

    property string leadingIcon: ""
    property string trailingIcon: ""
    property bool error: false
    property alias actions: actionRow.data
    readonly property color outline: error ? Theme.textField.error : activeFocus ? Theme.textField.focus : hovered ? Theme.textField.hover : Theme.textField.borderColor

    implicitWidth: Theme.size.panel.sm / 2
    implicitHeight: Math.max(Theme.textField.height, contentHeight + topPadding + bottomPadding)
    leftPadding: Theme.textField.paddingX + (leadingIcon !== "" ? Theme.icon.size.sm + Theme.textField.gap : 0)
    rightPadding: Theme.textField.paddingX + (trailing.width > 0 ? trailing.width + Theme.textField.gap : 0)
    verticalAlignment: TextInput.AlignVCenter
    hoverEnabled: true
    opacity: enabled ? 1 : Theme.opacity.disabled
    color: Theme.color.text
    placeholderTextColor: Theme.textField.placeholder
    selectionColor: Theme.textField.selection
    selectedTextColor: Theme.textField.selectedText
    font.family: Theme.text.body.family
    font.pixelSize: Theme.text.body.size
    font.weight: Theme.text.body.weight
    font.variableAxes: ({ wght: Theme.text.body.weight })
    Accessible.name: placeholderText

    background: Rectangle {
        radius: Theme.textField.radius
        color: Theme.textField.background
        border.width: Theme.textField.border
        border.color: root.outline
        Behavior on border.color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }

        Icon {
            visible: root.leadingIcon !== ""
            name: root.leadingIcon
            size: Theme.icon.size.sm
            color: Theme.textField.icon
            anchors.left: parent.left
            anchors.leftMargin: Theme.textField.paddingX
            anchors.verticalCenter: parent.verticalCenter
        }

        Label {
            role: "body"
            text: root.placeholderText
            color: Theme.textField.placeholder
            visible: root.text === "" && root.preeditText === ""
            x: root.leftPadding
            width: root.availableWidth
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
        }

        FocusRing { target: root }
    }

    // A child of the field, not of the background: the control puts its
    // background under itself, and the input takes every press on it, so
    // a button there would never be clicked.
    Row {
        id: trailing
        spacing: Theme.textField.gap
        anchors.right: parent.right
        anchors.rightMargin: Theme.textField.paddingX
        anchors.verticalCenter: parent.verticalCenter
        Icon {
            visible: root.trailingIcon !== ""
            name: root.trailingIcon
            size: Theme.icon.size.sm
            color: Theme.textField.icon
            anchors.verticalCenter: parent.verticalCenter
        }
        Row {
            id: actionRow
            spacing: Theme.textField.gap
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
