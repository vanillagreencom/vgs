import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

CloudSyncPage {
    id: page

    title: I18n.tr("Conflicts", "Cloud Sync conflicts page title")
    subtitle: I18n.tr("Files that changed on this computer and in the cloud at the same time. Both versions were kept — pick the one you want.", "Cloud Sync conflicts page subtitle")

    CloudSyncCard {
        visible: CloudSyncService.conflicts.length === 0
        iconName: "check_circle"
        title: I18n.tr("No conflicts", "Conflicts empty state title")
        description: I18n.tr("Two-way folders only create a conflict when the same file changes in both places between syncs. Nothing needs your attention right now.", "Conflicts empty state body")
    }

    Repeater {
        model: CloudSyncService.conflicts

        CloudSyncCard {
            id: conflictCard

            required property var modelData

            readonly property bool localIsNewer: (modelData.localMtime || 0) >= (modelData.cloudMtime || 0)

            iconName: "rule_folder"
            title: modelData.relPath
            description: modelData.folderName

            // Use matching fields for both conflict versions so the user can compare them.
            Item {
                width: parent.width
                height: Math.max(localSide.height, cloudSide.height)

                readonly property real halfWidth: (width - Theme.spacingM) / 2

                CloudSyncRow {
                    id: localSide

                    anchors.left: parent.left
                    width: parent.halfWidth
                    iconName: "computer"
                    title: I18n.tr("This computer", "Conflict side label for the local copy")
                    subtitle: CloudSyncService.formatBytes(conflictCard.modelData.localSize) + " · " + CloudSyncService.formatRelativeTime(conflictCard.modelData.localMtime)

                    trailing: [
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: conflictCard.localIsNewer
                            width: newerLocal.implicitWidth + Theme.spacingS
                            height: 18
                            radius: Theme.controlRadius
                            color: Theme.withAlpha(Theme.primary, 0.16)

                            StyledText {
                                id: newerLocal
                                anchors.centerIn: parent
                                text: I18n.tr("Newer", "Badge on the more recently modified conflict side")
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Medium
                                color: Theme.primary
                            }
                        }
                    ]
                }

                CloudSyncRow {
                    id: cloudSide

                    anchors.right: parent.right
                    width: parent.halfWidth
                    iconName: "cloud"
                    title: I18n.tr("Cloud", "Conflict side label for the remote copy")
                    subtitle: CloudSyncService.formatBytes(conflictCard.modelData.cloudSize) + " · " + CloudSyncService.formatRelativeTime(conflictCard.modelData.cloudMtime)

                    trailing: [
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !conflictCard.localIsNewer
                            width: newerCloud.implicitWidth + Theme.spacingS
                            height: 18
                            radius: Theme.controlRadius
                            color: Theme.withAlpha(Theme.primary, 0.16)

                            StyledText {
                                id: newerCloud
                                anchors.centerIn: parent
                                text: I18n.tr("Newer", "Badge on the more recently modified conflict side")
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Medium
                                color: Theme.primary
                            }
                        }
                    ]
                }
            }

            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: I18n.tr("The version you do not keep is moved to Cloud Sync's recycle bin, not deleted.", "Reassurance shown above the conflict resolution buttons")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS

                VgsButton {
                    text: I18n.tr("Keep this computer's", "Conflict action: keep the local copy")
                    iconName: "computer"
                    buttonHeight: 36
                    backgroundColor: Theme.primary
                    textColor: Theme.primaryText
                    onClicked: CloudSyncService.resolveConflict(conflictCard.modelData.id, "keepLocal", null)
                }

                VgsButton {
                    text: I18n.tr("Keep the cloud's", "Conflict action: keep the remote copy")
                    iconName: "cloud"
                    variant: "secondary"
                    buttonHeight: 36
                    onClicked: CloudSyncService.resolveConflict(conflictCard.modelData.id, "keepCloud", null)
                }

                VgsButton {
                    text: I18n.tr("Keep both", "Conflict action: rename and keep both copies")
                    iconName: "content_copy"
                    variant: "secondary"
                    buttonHeight: 36
                    onClicked: CloudSyncService.resolveConflict(conflictCard.modelData.id, "keepBoth", null)
                }
            }
        }
    }
}
