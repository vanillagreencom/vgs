import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// A multi-line text input. It uses the same outline, selection and
// typography tokens as TextField, while the caller owns its height.
T.TextArea {
    id: root

    property bool error: false
    readonly property color outline: error ? Theme.textField.error : activeFocus ? Theme.textField.focus : hovered ? Theme.textField.hover : Theme.textField.borderColor

    implicitWidth: Theme.size.panel.sm
    implicitHeight: Math.max(Theme.size.control.lg * 3, contentHeight + topPadding + bottomPadding)
    leftPadding: Theme.textField.paddingX
    rightPadding: Theme.textField.paddingX
    topPadding: Theme.textField.paddingX
    bottomPadding: Theme.textField.paddingX
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
    wrapMode: TextEdit.Wrap
    Accessible.name: placeholderText

    background: Rectangle {
        radius: Theme.textField.radius
        color: Theme.textField.background
        border.width: Theme.textField.border
        border.color: root.outline
        Behavior on border.color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
        FocusRing { target: root; offset: 0 }
    }
}
