import QtQuick
import qs.Common
import qs.Widgets

// The upgrade buttons for the updates sheet: one quiet row of per-source
// buttons, with Update All below as the primary action.
//
// Each button reports a `vshell update run` mode through `launchRequested`;
// the widget owns the command lookup and the terminal launch.
Column {
    id: actions

    property bool toolsAvailable: false

    signal launchRequested(string mode)

    spacing: Theme.spacingS

    Item {
        width: parent.width
        height: partialRow.height

        StyledText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Update"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        Row {
            id: partialRow
            anchors.right: parent.right
            spacing: Theme.spacingXS

            VgsButton {
                buttonHeight: 30
                horizontalPadding: Theme.spacingM
                text: "System"
                iconName: "download"
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: actions.launchRequested("system")
            }

            VgsButton {
                buttonHeight: 30
                horizontalPadding: Theme.spacingM
                text: "AUR"
                iconName: "deployed_code"
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: actions.launchRequested("aur")
            }

            VgsButton {
                visible: actions.toolsAvailable
                buttonHeight: 30
                horizontalPadding: Theme.spacingM
                text: "Dev tools"
                iconName: "smart_toy"
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: actions.launchRequested("tools")
            }
        }
    }

    VgsButton {
        width: parent.width
        text: "Update All"
        iconName: "browser_updated"
        backgroundColor: Theme.primary
        textColor: Theme.primaryText
        onClicked: actions.launchRequested("all")
    }
}
