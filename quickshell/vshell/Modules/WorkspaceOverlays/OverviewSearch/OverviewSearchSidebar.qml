pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

Rectangle {
    id: root

    property var controller: null
    signal categorySelected(string category)

    color: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
    border.color: Theme.borderColor
    border.width: 1
    radius: Theme.containerRadius

    Column {
        anchors.fill: parent
        anchors.margins: Theme.spacingS
        spacing: Theme.spacingXXS

        StyledText {
            width: parent.width
            height: 26
            leftPadding: Theme.spacingS
            text: I18n.tr("Browse").toUpperCase()
            font.pixelSize: Theme.fontSizeSmall - 1
            font.weight: Font.DemiBold
            font.letterSpacing: 0.6
            color: Theme.surfaceVariantText
            verticalAlignment: Text.AlignVCenter
        }

        Repeater {
            model: [
                { id: "apps", label: I18n.tr("Apps"), icon: "apps" },
                { id: "files", label: I18n.tr("Files"), icon: "folder" }
            ]

            Rectangle {
                id: navRow
                required property var modelData
                required property int index
                readonly property bool selected: root.controller?.searchMode === modelData.id

                width: parent.width
                height: 38
                radius: Theme.controlRadius
                color: selected ? Theme.surfaceSelected : navArea.containsMouse ? Theme.surfaceHover : "transparent"

                Rectangle {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: 2
                    height: 18
                    radius: 1
                    color: Theme.primary
                    visible: navRow.selected
                }

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingS

                    VgsIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: navRow.modelData.icon
                        size: 18
                        color: navRow.selected ? Theme.primary : Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: navRow.modelData.label
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: navRow.selected ? Font.Medium : Font.Normal
                        color: navRow.selected ? Theme.surfaceText : Theme.surfaceTextMedium
                    }
                }

                MouseArea {
                    id: navArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.categorySelected(navRow.modelData.id)
                }
            }
        }

        Item { width: 1; height: Theme.spacingS }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.separatorColor
        }

        StyledText {
            width: parent.width
            topPadding: Theme.spacingS
            leftPadding: Theme.spacingS
            text: "Ctrl+B  " + I18n.tr("toggle sidebar")
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
        }
    }
}
