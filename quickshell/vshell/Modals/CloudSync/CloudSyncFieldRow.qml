import QtQuick
import qs.Common
import qs.Widgets

// A short-value text field in the same shape as SettingsDropdownRow: label (and
// optional description) on the left, a compact control right-aligned to the
// card edge. Values like "2M" do not deserve a full-width field, and matching
// the dropdown geometry keeps every control in a card on one right edge.
Item {
    id: root

    property string text: ""
    property string description: ""
    property alias value: field.text
    property string placeholderText: ""
    property real fieldWidth: 200
    // The control gives way as the row narrows so the label never gets squeezed
    // to one word per line.
    readonly property real effectiveFieldWidth: Math.max(110, Math.min(fieldWidth, width * 0.5))

    signal editingFinished

    width: parent ? parent.width : 0
    height: Math.max(60, labelColumn.implicitHeight + Theme.spacingM)

    Column {
        id: labelColumn

        anchors.left: parent.left
        anchors.right: field.left
        anchors.rightMargin: Theme.spacingL
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingXS

        StyledText {
            width: parent.width
            text: root.text
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
            horizontalAlignment: Text.AlignLeft
        }

        StyledText {
            width: parent.width
            visible: root.description.length > 0
            text: root.description
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignLeft
        }
    }

    VgsTextField {
        id: field

        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: root.effectiveFieldWidth
        placeholderText: root.placeholderText
        onEditingFinished: root.editingFinished()
    }
}
