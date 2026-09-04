import QtQuick
import qs.Common
import qs.Widgets

// Shared status pill for folder state and account health.
Rectangle {
    id: root

    property string iconName: ""
    property string label: ""
    property color chipColor: Theme.surfaceVariantText

    width: contentRow.implicitWidth + Theme.spacingM
    height: 24
    radius: Theme.controlRadius
    color: Theme.withAlpha(root.chipColor, 0.14)

    Row {
        id: contentRow

        anchors.centerIn: parent
        spacing: Theme.spacingXXS

        VgsIcon {
            name: root.iconName
            size: 13
            color: root.chipColor
            anchors.verticalCenter: parent.verticalCenter
            visible: root.iconName.length > 0
        }

        StyledText {
            text: root.label
            font.pixelSize: Theme.fontSizeSmall - 1
            font.weight: Font.Medium
            color: root.chipColor
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
