import QtQuick
import qs.Common
import qs.Widgets

Column {
    id: root

    property string headerText: ""
    property string detailsText: ""
    property bool showCloseButton: false
    property var closePopout: null
    property var parentPopout: null
    property alias headerActions: headerActionsLoader.sourceComponent

    readonly property int headerHeight: popoutHeader.visible ? popoutHeader.height : 0
    readonly property int detailsHeight: popoutDetails.visible ? popoutDetails.implicitHeight : 0

    spacing: 0

    Item {
        id: popoutHeader
        width: parent.width
        // Height tracks the close button so the title's top padding matches the
        // popout's side padding instead of gaining extra space from a taller header.
        height: 32
        visible: headerText.length > 0

        StyledText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.headerText
            font.pixelSize: Theme.fontSizeXLarge
            font.weight: Font.Bold
            color: Theme.surfaceText
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            Loader {
                id: headerActionsLoader
                anchors.verticalCenter: parent.verticalCenter
            }

            Rectangle {
                id: closeButton
                width: 32
                height: 32
                radius: Theme.controlRadius
                color: closeArea.containsMouse ? Theme.errorHover : Theme.withAlpha(Theme.errorHover, 0)
                visible: root.showCloseButton

                VgsIcon {
                    anchors.centerIn: parent
                    name: "close"
                    size: Theme.iconSize - 4
                    color: closeArea.containsMouse ? Theme.error : Theme.surfaceText
                }

                MouseArea {
                    id: closeArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPressed: {
                        if (root.closePopout) {
                            root.closePopout();
                        }
                    }
                }
            }
        }
    }

    StyledText {
        id: popoutDetails
        width: parent.width
        bottomPadding: Theme.spacingS
        text: root.detailsText
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
        visible: detailsText.length > 0
        wrapMode: Text.WordWrap
    }
}
