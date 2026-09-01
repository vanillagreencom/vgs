pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

Item {
    id: root

    property string iconName: ""
    property string title: ""
    property string description: ""

    width: parent?.width ?? 0
    height: Math.max(iconBox.height, textColumn.implicitHeight)

    Rectangle {
        id: iconBox

        width: 40
        height: 40
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        radius: Theme.controlRadius
        color: Theme.primarySelected

        VgsIcon {
            anchors.centerIn: parent
            name: root.iconName
            size: Theme.iconSize
            color: Theme.primary
        }
    }

    Column {
        id: textColumn

        anchors.left: iconBox.right
        anchors.right: parent.right
        anchors.leftMargin: Theme.spacingM
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingXXS

        StyledText {
            text: root.title
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
            width: parent.width
            horizontalAlignment: Text.AlignLeft
        }

        StyledText {
            text: root.description
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            width: parent.width
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignLeft
        }
    }
}
