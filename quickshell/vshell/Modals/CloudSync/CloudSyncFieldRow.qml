import QtQuick
import qs.Common
import qs.Widgets

// Compact field row with its control aligned to the dropdown rows in the same card.
Item {
    id: root

    property string text: ""
    property string description: ""
    property alias value: field.text
    property string placeholderText: ""
    property real fieldWidth: 200
    // Shrink the control before reducing the label to a narrow column.
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
