import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// Two-way sync needs one comparison it cannot make on its own: the very first
// time, when both sides have files and no shared history, something has to win.
// The backend refuses to guess, so this dialog is the only way to establish a
// baseline.
CloudSyncDialog {
    id: dialog

    property var parentModal: null
    property string folderId: ""
    property string side: ""

    readonly property var folder: CloudSyncService.folderById(folderId) || ({})
    readonly property bool isFirstRun: folder.resyncDone !== true

    readonly property var choices: [
        {
            "id": "local",
            "icon": "computer",
            "title": I18n.tr("This computer wins", "Resync option: local side is authoritative"),
            "body": I18n.tr("Files here are copied up. Cloud files that are different are replaced, and their old versions go to the recycle bin.", "Resync option explanation: local wins")
        },
        {
            "id": "cloud",
            "icon": "cloud",
            "title": I18n.tr("The cloud wins", "Resync option: remote side is authoritative"),
            "body": I18n.tr("Files in the cloud are copied down. Local files that are different are replaced, and their old versions go to the recycle bin.", "Resync option explanation: cloud wins")
        },
        {
            "id": "newer",
            "icon": "schedule",
            "title": I18n.tr("The newer file wins", "Resync option: most recently modified side is authoritative"),
            "body": I18n.tr("Compares each file and keeps whichever was edited most recently. Good when both sides have work you want to keep.", "Resync option explanation: newer wins")
        }
    ]

    title: isFirstRun ? I18n.tr("Set up two-way sync", "Resync dialog title on first run") : I18n.tr("Rebuild the two-way baseline", "Resync dialog title when re-running a resync")
    subtitle: folder.name || folder.localPath || ""
    confirmText: I18n.tr("Start", "Button that begins the resync")
    confirmEnabled: side.length > 0
    dialogWidth: 560

    onCancelled: {
        if (dialog.parentModal)
            dialog.parentModal.closeDialog();
    }

    onConfirmed: {
        CloudSyncService.resync(dialog.folderId, dialog.side, null);
        if (dialog.parentModal)
            dialog.parentModal.closeDialog();
    }

    StyledText {
        width: parent.width
        wrapMode: Text.WordWrap
        text: I18n.tr("Both sides already have files and no shared history, so the first comparison needs a rule. After this, changes flow both ways automatically.", "Explanation of why a bisync baseline is required")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    Repeater {
        model: dialog.choices

        CloudSyncRow {
            required property var modelData

            iconName: modelData.icon
            iconColor: selected ? Theme.primary : Theme.surfaceVariantText
            iconSize: Theme.iconSize
            interactive: true
            selected: dialog.side === modelData.id
            title: modelData.title
            subtitle: modelData.body
            subtitleWrap: true

            onClicked: dialog.side = modelData.id
        }
    }

    StyledRect {
        width: parent.width
        height: safetyColumn.implicitHeight + Theme.spacingM * 2
        radius: Theme.controlRadius
        color: Theme.warningContainer

        Column {
            id: safetyColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            spacing: Theme.spacingXXS

            Row {
                spacing: Theme.spacingXS

                VgsIcon {
                    name: "shield"
                    size: Theme.iconSizeSmall
                    color: Theme.warning
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: I18n.tr("Nothing is deleted outright", "Safety note heading on the resync dialog")
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: I18n.tr("Anything replaced during the baseline is moved to Cloud Sync's recycle bin first, on both sides. You can get it back from Settings.", "Safety note body on the resync dialog")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceTextMedium
            }
        }
    }
}
