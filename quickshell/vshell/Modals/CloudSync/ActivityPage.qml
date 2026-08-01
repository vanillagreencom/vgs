import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

CloudSyncPage {
    id: page

    title: I18n.tr("Activity", "Cloud Sync activity page title")
    subtitle: I18n.tr("What is moving right now, and what has moved recently.", "Cloud Sync activity page subtitle")

    headerAction: [
        VgsButton {
            text: CloudSyncService.isSyncing ? I18n.tr("Syncing…", "Disabled button label while a sync is running") : I18n.tr("Sync all now", "Button that syncs every folder")
            iconName: "sync"
            variant: "secondary"
            buttonHeight: 36
            enabled: CloudSyncService.daemonRunning && CloudSyncService.hasFolders && !CloudSyncService.isSyncing
            onClicked: CloudSyncService.syncNow("", null)
        }
    ]

    // ---- Live transfers ----
    CloudSyncCard {
        visible: CloudSyncService.transferring.length > 0
        iconName: "swap_vert"
        title: I18n.tr("Transferring now", "Activity section title for in-progress files")
        description: {
            const parts = [];
            if (CloudSyncService.uploadSpeed > 0)
                parts.push("↑ " + CloudSyncService.formatSpeed(CloudSyncService.uploadSpeed));
            if (CloudSyncService.downloadSpeed > 0)
                parts.push("↓ " + CloudSyncService.formatSpeed(CloudSyncService.downloadSpeed));
            const eta = CloudSyncService.formatDuration(CloudSyncService.etaSeconds);
            if (eta.length > 0)
                parts.push(I18n.tr("about", "Precedes an estimated remaining time") + " " + eta + " " + I18n.tr("left", "Suffix after an estimated remaining time"));
            return parts.join(" · ");
        }

        Repeater {
            model: CloudSyncService.transferring

            CloudSyncRow {
                required property var modelData

                iconName: modelData.direction === "down" ? "download" : "upload"
                title: modelData.name || ""
                subtitle: modelData.folderName || ""

                trailing: [
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: CloudSyncService.formatSpeed(modelData.speed)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                ]

                body: [
                    CloudSyncProgressBar {
                        fraction: (modelData.percentage || 0) / 100
                    },
                    StyledText {
                        width: parent.width
                        horizontalAlignment: Text.AlignRight
                        text: CloudSyncService.formatBytes(modelData.bytes) + " / " + CloudSyncService.formatBytes(modelData.size)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                ]
            }
        }
    }

    // ---- Idle state ----
    CloudSyncCard {
        visible: CloudSyncService.transferring.length === 0 && CloudSyncService.recent.length === 0 && CloudSyncService.history.length === 0
        iconName: "history"
        title: I18n.tr("Nothing has synced yet", "Activity empty state title")
        description: CloudSyncService.hasFolders ? I18n.tr("Runs will show up here as they happen.", "Activity empty state body when folders exist") : I18n.tr("Add a folder to start syncing.", "Activity empty state body when no folders exist")
    }

    // ---- Recently synced files ----
    CloudSyncCard {
        visible: CloudSyncService.recent.length > 0
        iconName: "task_alt"
        title: I18n.tr("Recent files", "Activity section title for completed file transfers")

        Repeater {
            model: CloudSyncService.recent

            CloudSyncRow {
                required property var modelData

                iconName: modelData.error ? "error" : (modelData.direction === "down" ? "download_done" : "cloud_done")
                iconColor: modelData.error ? Theme.error : Theme.success
                title: modelData.name || ""
                subtitle: modelData.error && modelData.error.length > 0 ? modelData.error : modelData.folderName
                subtitleColor: modelData.error && modelData.error.length > 0 ? Theme.error : Theme.surfaceVariantText

                trailing: [
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: CloudSyncService.formatBytes(modelData.size)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    },
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: modelData.completedUnix > 0
                        text: CloudSyncService.formatRelativeTime(modelData.completedUnix)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                ]
            }
        }
    }

    // ---- Run history ----
    CloudSyncCard {
        visible: CloudSyncService.history.length > 0
        iconName: "schedule"
        title: I18n.tr("Sync history", "Activity section title for completed sync runs")

        Repeater {
            model: CloudSyncService.history.slice(0, 40)

            CloudSyncRow {
                required property var modelData

                iconName: modelData.success ? "check_circle" : "error"
                iconColor: modelData.success ? Theme.success : Theme.error
                title: modelData.folderName || ""
                subtitleColor: modelData.success ? Theme.surfaceVariantText : Theme.error
                subtitle: {
                    if (!modelData.success && modelData.error)
                        return modelData.error;
                    const parts = [];
                    if (modelData.transfers > 0)
                        parts.push(modelData.transfers === 1 ? I18n.tr("1 file", "Sync history summary, single transferred file") : modelData.transfers + " " + I18n.tr("files", "Suffix after a file count in sync history"));
                    if (modelData.bytes > 0)
                        parts.push(CloudSyncService.formatBytes(modelData.bytes));
                    if (parts.length === 0)
                        parts.push(I18n.tr("No changes", "Sync history entry with nothing to transfer"));
                    const duration = modelData.finishedUnix - modelData.startedUnix;
                    if (duration > 0)
                        parts.push(CloudSyncService.formatDuration(duration));
                    return parts.join(" · ");
                }

                trailing: [
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: CloudSyncService.formatRelativeTime(modelData.finishedUnix)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                ]
            }
        }
    }
}
