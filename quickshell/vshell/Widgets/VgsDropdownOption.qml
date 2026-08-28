import QtQuick
import qs.Common
import qs.Widgets

Rectangle {
    id: root

    required property var modelData
    required property int index
    property bool selected: false
    property bool current: false
    property bool multiSelect: false
    property string optionIcon: ""
    property var optionColor
    property bool fitContent: false

    signal clicked

    height: 32
    radius: Theme.controlRadius
    color: selected ? Theme.primaryHover : optionArea.containsMouse ? Theme.primaryHoverLight : Theme.withAlpha(Theme.primaryHoverLight, 0)

    Row {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.spacingS
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingS

        Rectangle {
            id: optionCheck

            width: 16
            height: 16
            anchors.verticalCenter: parent.verticalCenter
            visible: root.multiSelect
            radius: 3
            color: root.current ? Theme.primary : "transparent"
            border.width: 1
            border.color: root.current ? Theme.primary : Theme.borderColor

            VgsIcon {
                anchors.centerIn: parent
                name: "check"
                size: 13
                color: Theme.primaryText
                visible: root.current
            }
        }

        VgsColorSwatch {
            id: optionSwatch

            width: 16
            height: 16
            anchors.verticalCenter: parent.verticalCenter
            visible: root.optionColor !== undefined
            swatchColor: visible ? root.optionColor : Theme.withAlpha(root.optionColor, 0)
            ringColor: root.current ? Theme.primary : Theme.outline
        }

        VgsIcon {
            name: root.optionIcon
            size: 18
            color: root.current ? Theme.primary : Theme.surfaceText
            visible: name !== ""
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: root.modelData
            font.pixelSize: Theme.fontSizeMedium
            color: root.current ? Theme.primary : Theme.surfaceText
            font.weight: root.current ? Font.Medium : Font.Normal
            width: root.fitContent ? undefined : root.width - parent.x - Theme.spacingS * 2 - (optionCheck.visible ? optionCheck.width + parent.spacing : 0) - (optionSwatch.visible ? optionSwatch.width + parent.spacing : 0)
            elide: root.fitContent ? Text.ElideNone : Text.ElideRight
            wrapMode: Text.NoWrap
            horizontalAlignment: Text.AlignLeft
        }
    }

    MouseArea {
        id: optionArea

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
