import QtQuick
import qs.Common
import qs.Widgets

// One checkbox row of the provider filter. The whole row is the hit target for
// the checkbox; only the setup button at the far end is separate, so a click
// aimed at a provider name never opens its settings by accident.
Item {
    id: row

    property string label: ""
    // The AiUsageWidget root, for the provider's own mark. Absent on the "All" row.
    property var host: null
    property string provider: ""
    property bool checked: false
    property bool showSetup: false

    signal toggled
    signal setupClicked

    width: parent ? parent.width : 0
    height: 32

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: Theme.spacingXS
        anchors.rightMargin: Theme.spacingXS
        radius: Theme.controlRadius
        color: rowArea.containsMouse ? Theme.surfaceTextHover : "transparent"
    }

    MouseArea {
        id: rowArea
        anchors.fill: parent
        anchors.rightMargin: row.showSetup ? setupButton.width + Theme.spacingXS : 0
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.toggled()
    }

    VgsIcon {
        id: box
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingM
        anchors.verticalCenter: parent.verticalCenter
        name: row.checked ? "check_box" : "check_box_outline_blank"
        size: Theme.iconSizeSmall
        color: row.checked ? Theme.primary : Theme.surfaceVariantText
    }

    AiUsageProviderIcon {
        id: providerIcon
        anchors.left: box.right
        anchors.leftMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        host: row.host
        provider: row.provider
        size: Theme.iconSizeSmall
        color: Theme.surfaceVariantText
        visible: row.provider !== ""
    }

    StyledText {
        anchors.left: row.provider !== "" ? providerIcon.right : box.right
        anchors.leftMargin: Theme.spacingS
        anchors.right: row.showSetup ? setupButton.left : parent.right
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        text: row.label
        elide: Text.ElideRight
        font.pixelSize: Theme.fontSizeSmall
        font.weight: row.checked ? Font.Medium : Font.Normal
        color: row.checked ? Theme.surfaceText : Theme.surfaceVariantText
    }

    VgsActionButton {
        id: setupButton
        anchors.right: parent.right
        anchors.rightMargin: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter
        visible: row.showSetup
        iconName: "tune"
        iconSize: Theme.iconSizeSmall
        buttonSize: 26
        iconColor: Theme.surfaceVariantText
        tooltipText: "Where this provider's accounts come from"
        onClicked: row.setupClicked()
    }
}
