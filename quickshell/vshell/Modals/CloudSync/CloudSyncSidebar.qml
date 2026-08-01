import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// Flat, always-visible navigation (Vercel/Linear style): quiet rows, an active
// pill, no ripples. Matches the Settings sidebar language.
Item {
    id: root

    property var sections: []
    property int currentIndex: 0

    signal sectionRequested(int index)

    implicitWidth: 220

    Rectangle {
        anchors.fill: parent
        color: Theme.popupGlassEffect ? "transparent" : Theme.surfaceContainerLow
    }

    Rectangle {
        anchors.right: parent.right
        width: 1
        height: parent.height
        color: Theme.separatorColor
    }

    Column {
        id: header

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Theme.spacingXL + Theme.spacingXS
        anchors.leftMargin: Theme.spacingL
        anchors.rightMargin: Theme.spacingL
        spacing: Theme.spacingXXS

        Row {
            spacing: Theme.spacingS

            VgsIcon {
                name: "cloud_sync"
                size: Theme.iconSize
                color: Theme.primary
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: I18n.tr("Cloud Sync", "Cloud Sync sidebar title")
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Theme.fontWeightSectionHeader
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        StyledText {
            width: parent.width
            text: {
                if (!CloudSyncService.available)
                    return I18n.tr("rclone not installed", "Cloud Sync sidebar status when the engine is missing");
                if (!CloudSyncService.daemonRunning)
                    return I18n.tr("Engine stopped", "Cloud Sync sidebar status when rclone is not running");
                if (CloudSyncService.paused)
                    return I18n.tr("Paused", "Cloud Sync sidebar status when sync is paused");
                if (CloudSyncService.isSyncing)
                    return CloudSyncService.formatSpeed(CloudSyncService.aggregateSpeed) || I18n.tr("Syncing…", "Cloud Sync sidebar status while syncing");
                if (!CloudSyncService.hasAccounts)
                    return I18n.tr("Not set up yet", "Cloud Sync sidebar status before any account is connected");
                // An unreachable account stops everything under it, so the
                // header must not claim "Up to date" while one is broken.
                if (CloudSyncService.unhealthyAccounts.length > 0)
                    return I18n.tr("Account needs attention", "Cloud Sync sidebar status when an account cannot be reached");
                if (CloudSyncService.erroredStatuses.length > 0)
                    return I18n.tr("Needs attention", "Cloud Sync sidebar status when a folder failed to sync");
                return I18n.tr("Up to date", "Cloud Sync sidebar status when idle");
            }
            elide: Text.ElideRight
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    Column {
        id: nav

        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Theme.spacingXL
        anchors.leftMargin: Theme.spacingS
        anchors.rightMargin: Theme.spacingS
        spacing: Theme.spacingXXS

        StyledText {
            leftPadding: Theme.spacingS
            bottomPadding: Theme.spacingXS
            text: I18n.tr("MANAGE", "Cloud Sync sidebar group header")
            font.pixelSize: Theme.fontSizeSmall - 1
            font.weight: Font.DemiBold
            font.letterSpacing: 0.6
            color: Theme.surfaceVariantText
        }

        Repeater {
            model: root.sections

            Rectangle {
                required property var modelData
                required property int index

                readonly property bool isActive: root.currentIndex === index
                // The conflicts row carries a count badge, because an unresolved
                // conflict is the one thing in this app that needs a decision.
                readonly property int badgeCount: modelData.id === "conflicts" ? CloudSyncService.conflictCount : 0

                width: parent.width
                height: 36
                radius: Theme.controlRadius
                color: isActive ? Theme.surfaceSelected : (rowArea.containsMouse ? Theme.surfaceHover : "transparent")

                Row {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    spacing: Theme.spacingS

                    VgsIcon {
                        name: modelData.icon
                        size: Theme.iconSizeSmall
                        color: parent.parent.isActive ? Theme.surfaceText : Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: modelData.text
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: parent.parent.isActive ? Font.Medium : Font.Normal
                        color: parent.parent.isActive ? Theme.surfaceText : Theme.surfaceTextMedium
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Rectangle {
                    visible: parent.badgeCount > 0
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(18, badgeText.implicitWidth + Theme.spacingS)
                    height: 18
                    radius: height / 2
                    color: Theme.warning

                    StyledText {
                        id: badgeText
                        anchors.centerIn: parent
                        text: String(parent.parent.badgeCount)
                        font.pixelSize: Theme.fontSizeSmall - 1
                        font.weight: Font.DemiBold
                        color: Theme.background
                    }
                }

                MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.sectionRequested(parent.index)
                }
            }
        }
    }

    // Engine state footer: version and a restart affordance, so a stuck rclone
    // is diagnosable without leaving the app.
    Column {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingXS

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.separatorColor
        }

        StyledText {
            visible: CloudSyncService.rcloneVersion.length > 0
            width: parent.width
            topPadding: Theme.spacingXS
            text: "rclone " + CloudSyncService.rcloneVersion
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
            elide: Text.ElideRight
        }

        VgsButton {
            visible: CloudSyncService.available && !CloudSyncService.daemonRunning
            width: parent.width
            text: I18n.tr("Restart engine", "Cloud Sync sidebar button that restarts rclone")
            iconName: "restart_alt"
            variant: "secondary"
            buttonHeight: 30
            onClicked: CloudSyncService.restartDaemon(null)
        }
    }
}
