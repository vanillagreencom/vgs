import QtQuick
import qs.Common
import qs.Widgets

Rectangle {
    id: root

    property string iconName: ""
    property string title: ""
    property string description: ""
    property string keyHint: ""
    property bool selected: false

    signal clicked

    radius: Theme.containerRadius
    color: {
        if (root.selected)
            return Theme.surfaceSelected;
        if (mouseArea.containsMouse)
            return Theme.surfaceHover;
        return Theme.surfaceContainerHigh;
    }

    border.width: root.selected ? 1 : 0
    border.color: Theme.primary
    opacity: root.enabled ? 1 : 0.4

    Behavior on color {
        ColorAnimation {
            duration: Theme.shorterDuration
            easing.type: Theme.standardEasing
        }
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Theme.spacingM
        anchors.rightMargin: Theme.spacingM
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingS

        VgsIcon {
            name: root.iconName
            size: Theme.iconSize + 2
            color: root.selected ? Theme.primary : Theme.surfaceText
        }

        StyledText {
            width: parent.width
            text: root.title
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.DemiBold
            color: Theme.surfaceText
            elide: Text.ElideRight
        }

        StyledText {
            width: parent.width
            text: root.description
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceTextSecondary
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        enabled: root.enabled
        hoverEnabled: true
        cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.clicked()
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -Theme.focusRingWidth
        radius: root.radius + Theme.focusRingWidth
        color: "transparent"
        border.width: Theme.focusRingWidth
        border.color: Theme.focusRing
        visible: root.activeFocus
    }

    activeFocusOnTab: enabled
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.clicked();
            event.accepted = true;
        }
    }
}
