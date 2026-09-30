import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// A one-line text input. `leadingIcon` and `trailingIcon` name Lucide
// icons drawn inside the field; `actions` holds buttons drawn after the
// trailing icon, such as a clear or a submit button; `error` colours the
// outline with the error colour; `password` masks what is typed, for a
// secret the shell stores (D058), and Qt then keeps it off the clipboard. The template owns the text, the cursor,
// the selection, `validator` and `acceptableInput`; the outline follows
// hover, focus and error, in that order of precedence reversed, and the
// focus ring of a field in error draws in the error colour, so the cue
// stays while the user edits. Its icons are the `md` control's; under a
// rounded theme the side padding grows until the text clears the corner.
T.TextField {
    id: root

    property string leadingIcon: ""
    property string trailingIcon: ""
    property bool error: false
    property bool password: false
    property alias actions: actionRow.data
    readonly property color outline: error ? Theme.textField.error : activeFocus ? Theme.textField.focus : hovered ? Theme.textField.hover : Theme.textField.borderColor
    readonly property real sidePadding: Theme.controlPadding(Theme.textField.paddingX, Theme.textField.radius, Math.max(Theme.textField.height, height), contentHeight)

    implicitWidth: Theme.size.panel.sm / 2
    implicitHeight: Math.max(Theme.textField.height, contentHeight + topPadding + bottomPadding)
    leftPadding: sidePadding + (leadingIcon !== "" ? Theme.icon.size.md + Theme.textField.gap : 0)
    rightPadding: sidePadding + (trailing.width > 0 ? trailing.width + Theme.textField.gap : 0)
    verticalAlignment: TextInput.AlignVCenter
    echoMode: password ? TextInput.Password : TextInput.Normal
    hoverEnabled: true
    opacity: enabled ? 1 : Theme.opacity.disabled
    color: Theme.color.text
    placeholderTextColor: Theme.textField.placeholder
    selectionColor: Theme.textField.selection
    selectedTextColor: Theme.textField.selectedText
    font.family: Theme.text.item.family
    font.pixelSize: Theme.text.item.size
    font.weight: Theme.text.item.weight
    font.variableAxes: ({ wght: Theme.text.item.weight })
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
            size: Theme.icon.size.md
            color: Theme.textField.icon
            anchors.left: parent.left
            anchors.leftMargin: root.sidePadding
            anchors.verticalCenter: parent.verticalCenter
        }

        Label {
            role: "item"
            text: root.placeholderText
            color: Theme.textField.placeholder
            visible: root.text === "" && root.preeditText === ""
            x: root.leftPadding
            width: root.availableWidth
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
        }

        FocusRing { target: root; offset: 0; ringColor: root.error ? Theme.textField.error : Theme.focusRing.color }
    }

    // A child of the field, not of the background: the control puts its
    // background under itself, and the input takes every press on it, so
    // a button there would never be clicked.
    Row {
        id: trailing
        spacing: Theme.textField.gap
        anchors.right: parent.right
        anchors.rightMargin: root.sidePadding
        anchors.verticalCenter: parent.verticalCenter
        Icon {
            visible: root.trailingIcon !== ""
            name: root.trailingIcon
            size: Theme.icon.size.md
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
