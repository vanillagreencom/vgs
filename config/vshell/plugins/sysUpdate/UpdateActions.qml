import QtQuick
import qs.Common
import qs.Widgets

// Expose upgrade actions for pending sources. With one pending source, the
// primary action names it. Unknown counts retain the available actions.
// Report the selected mode through launchRequested; the widget owns launch.
Column {
    id: actions

    // The widget root, read for the counts and the check's health.
    property var host

    signal launchRequested(string mode)

    // A failed check zeroes the counts, so they say nothing about what is
    // pending; only a clean check may narrow the buttons.
    readonly property bool countsKnown: host.errorText.length === 0 && host.toolsError.length === 0
    readonly property bool systemPending: !countsKnown || host.repoCount > 0
    readonly property bool aurPending: !countsKnown || host.aurCount > 0
    readonly property bool toolsPending: host.toolsAvailable && (!countsKnown || host.toolsCount > 0)
    readonly property int pendingCount: (systemPending ? 1 : 0) + (aurPending ? 1 : 0) + (toolsPending ? 1 : 0)

    // The single pending source, or "all" when several are.
    readonly property string primaryMode: pendingCount !== 1 ? "all" : (systemPending ? "system" : (aurPending ? "aur" : "tools"))

    spacing: Theme.spacingS

    Item {
        width: parent.width
        height: partialRow.height
        visible: actions.pendingCount > 1

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
                visible: actions.systemPending
                buttonHeight: 30
                horizontalPadding: Theme.spacingM
                text: "System"
                iconName: "download"
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: actions.launchRequested("system")
            }

            VgsButton {
                visible: actions.aurPending
                buttonHeight: 30
                horizontalPadding: Theme.spacingM
                text: "AUR"
                iconName: "deployed_code"
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                onClicked: actions.launchRequested("aur")
            }

            VgsButton {
                visible: actions.toolsPending
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
        text: actions.primaryMode === "all" ? "Update All" : (actions.primaryMode === "system" ? "Update System" : (actions.primaryMode === "aur" ? "Update AUR" : "Update Dev Tools"))
        iconName: "browser_updated"
        backgroundColor: Theme.primary
        textColor: Theme.primaryText
        onClicked: actions.launchRequested(actions.primaryMode)
    }
}
