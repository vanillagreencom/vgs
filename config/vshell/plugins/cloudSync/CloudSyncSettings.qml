import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "cloudSync"

    StyledText {
        width: parent.width
        text: I18n.tr("Cloud Sync Settings", "Plugin settings page title")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: I18n.tr("Show cloud sync state in the bar. Click the pill for live transfers, storage and quick controls; open the Cloud Sync app to manage accounts and folders.", "Plugin settings description")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledRect {
        width: parent.width
        height: configColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.borderColor

        Column {
            id: configColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            SelectionSetting {
                settingKey: "pillMode"
                label: I18n.tr("Pill label", "Setting: what the bar pill shows")
                description: I18n.tr("What the bar pill shows next to the icon", "Setting description")
                defaultValue: "status"
                options: [
                    {
                        value: "icon",
                        label: I18n.tr("Icon only", "Pill label option")
                    },
                    {
                        value: "status",
                        label: I18n.tr("Status", "Pill label option showing a word like Synced or Syncing")
                    },
                    {
                        value: "speed",
                        label: I18n.tr("Transfer speed", "Pill label option showing bytes per second")
                    },
                    {
                        value: "count",
                        label: I18n.tr("File count", "Pill label option showing how many files are moving")
                    }
                ]
            }

            ToggleSetting {
                settingKey: "hideWhenIdle"
                label: I18n.tr("Hide when up to date", "Setting: only show the pill when something needs attention")
                description: I18n.tr("Only show the pill while syncing, paused, or when something needs attention", "Setting description")
                defaultValue: false
            }
        }
    }

    StyledRect {
        width: parent.width
        height: infoColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surface
        border.width: 1
        border.color: Theme.borderColor

        Column {
            id: infoColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            Row {
                spacing: Theme.spacingM

                VgsIcon {
                    name: "info"
                    size: Theme.iconSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: I18n.tr("Requirements", "Settings section header")
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                width: parent.width
                text: I18n.tr("Needs the `rclone` command. Streaming folders on demand also needs `fuse3`. The widget hides itself when rclone is not installed.", "Cloud sync dependency explanation")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }

            StyledText {
                visible: CloudSyncService.rcloneVersion.length > 0
                width: parent.width
                text: I18n.tr("Detected rclone", "Label before the detected rclone version") + ": " + CloudSyncService.rcloneVersion
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceTextMedium
            }
        }
    }
}
