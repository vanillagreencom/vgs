import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

CloudSyncPage {
    id: page

    title: I18n.tr("Settings", "Cloud Sync settings page title")
    subtitle: I18n.tr("How Cloud Sync behaves across every folder.", "Cloud Sync settings page subtitle")

    readonly property var settings: CloudSyncService.settings

    // Bandwidth values use rclone rate strings such as 2M; empty means unlimited.
    CloudSyncCard {
        iconName: "speed"
        title: I18n.tr("Transfer speed", "Settings card title for bandwidth limits")
        description: I18n.tr("Leave a field empty for no limit. Use values like 2M or 500k.", "Settings card body for bandwidth limits")

        CloudSyncFieldRow {
            id: upField
            text: I18n.tr("Upload limit", "Bandwidth field label")
            value: page.settings.bandwidthUp || ""
            placeholderText: I18n.tr("Unlimited", "Placeholder for an unset bandwidth limit")
            onEditingFinished: CloudSyncService.setBandwidthLimit(upField.value, downField.value, null)
        }

        CloudSyncFieldRow {
            id: downField
            text: I18n.tr("Download limit", "Bandwidth field label")
            value: page.settings.bandwidthDown || ""
            placeholderText: I18n.tr("Unlimited", "Placeholder for an unset bandwidth limit")
            onEditingFinished: CloudSyncService.setBandwidthLimit(upField.value, downField.value, null)
        }
    }

    CloudSyncCard {
        iconName: "sync_alt"
        title: I18n.tr("Parallel transfers", "Settings card title for concurrency")
        description: I18n.tr("Higher values finish large batches faster but use more bandwidth and CPU.", "Settings card body for concurrency")

        CloudSyncDropdownRow {
            text: I18n.tr("Files at once", "Setting label for rclone --transfers")
            options: ["1", "2", "4", "8", "16"]
            currentValue: String(page.settings.transfers || 4)
            onValueChanged: value => CloudSyncService.updateSettings({
                "transfers": parseInt(value, 10)
            }, null)
        }

        CloudSyncDropdownRow {
            text: I18n.tr("Comparisons at once", "Setting label for rclone --checkers")
            description: I18n.tr("How many files are compared in parallel while looking for changes", "Setting description for rclone --checkers")
            options: ["2", "4", "8", "16", "32"]
            currentValue: String(page.settings.checkers || 8)
            onValueChanged: value => CloudSyncService.updateSettings({
                "checkers": parseInt(value, 10)
            }, null)
        }
    }

    CloudSyncCard {
        iconName: "notifications"
        title: I18n.tr("Notifications", "Settings card title for toasts")

        SettingsToggleRow {
            text: I18n.tr("Tell me when a sync fails", "Notification setting label")
            description: I18n.tr("Show a notification when a folder cannot sync", "Notification setting description")
            checked: page.settings.notifyErrors !== false
            onToggled: checked => CloudSyncService.updateSettings({
                "notifyErrors": checked
            }, null)
        }

        SettingsToggleRow {
            text: I18n.tr("Tell me when a sync finishes", "Notification setting label")
            description: I18n.tr("Show a notification after every run that transferred something", "Notification setting description")
            checked: page.settings.notifyCompletions === true
            onToggled: checked => CloudSyncService.updateSettings({
                "notifyCompletions": checked
            }, null)
        }
    }


    CloudSyncCard {
        iconName: "delete_sweep"
        title: I18n.tr("Recycle bin", "Settings card title for the sync trash")
        description: I18n.tr("Files that sync deletes or overwrites are moved here first, on both this computer and in the cloud.", "Settings card body for the sync trash")

        CloudSyncDropdownRow {
            text: I18n.tr("Keep deleted files for", "Setting label for trash retention")
            options: ["7", "14", "30", "90", "365"].map(days => days + " " + I18n.tr("days", "Suffix after a number of days"))
            currentValue: String(page.settings.trashRetentionDays || 30) + " " + I18n.tr("days", "Suffix after a number of days")
            onValueChanged: value => CloudSyncService.updateSettings({
                "trashRetentionDays": parseInt(value, 10)
            }, null)
        }

        VgsButton {
            text: I18n.tr("Empty recycle bin now", "Button that clears the sync trash")
            iconName: "delete_forever"
            variant: "secondary"
            buttonHeight: 36
            enabled: CloudSyncService.hasFolders
            onClicked: CloudSyncService.emptyTrash("", null)
        }
    }

    CloudSyncCard {
        visible: CloudSyncService.canMount
        iconName: "cloud_sync"
        title: I18n.tr("Streamed folders", "Settings card title for FUSE mounts")
        description: I18n.tr("Where on-demand folders appear. Changing this only affects folders you add afterwards.", "Settings card body for the mount root")

        VgsTextField {
            id: mountRootField
            width: parent.width
            text: page.settings.mountRoot || ""
            placeholderText: "~/CloudSync"
            onEditingFinished: CloudSyncService.updateSettings({
                "mountRoot": mountRootField.text
            }, null)
        }
    }

    CloudSyncCard {
        visible: !CloudSyncService.canMount
        iconName: "cloud_off"
        title: I18n.tr("Streaming is unavailable", "Settings card title when FUSE is missing")
        description: I18n.tr("Install fuse3 to mount cloud folders on demand. Folder sync works without it.", "Settings card body when FUSE is missing")
    }

    CloudSyncCard {
        iconName: "settings_ethernet"
        title: I18n.tr("Sync engine", "Settings card title for rclone status")
        description: I18n.tr("Cloud Sync runs rclone in the background. Accounts are stored in rclone's own config file, so they also work from the command line.", "Settings card body explaining the rclone relationship")

        CloudSyncRow {
            iconName: CloudSyncService.daemonRunning ? "check_circle" : "error"
            iconColor: CloudSyncService.daemonRunning ? Theme.success : Theme.error
            title: CloudSyncService.daemonRunning ? "rclone " + CloudSyncService.rcloneVersion : I18n.tr("Not running", "Engine status")
            subtitle: CloudSyncService.daemonRunning ? I18n.tr("Running in the background", "Engine status detail") : (CloudSyncService.daemonError || "")

            trailing: [
                VgsButton {
                    text: I18n.tr("Restart", "Button that restarts the rclone daemon")
                    iconName: "restart_alt"
                    variant: "secondary"
                    buttonHeight: 32
                    horizontalPadding: Theme.spacingM
                    onClicked: CloudSyncService.restartDaemon(null)
                }
            ]
        }
    }
}
