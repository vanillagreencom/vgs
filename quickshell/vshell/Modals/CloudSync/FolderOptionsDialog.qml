import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets
import "CloudSyncIcons.js" as CloudIcons

// Edits the settings a folder can safely change in place. Mode, account and
// paths are fixed after creation: changing them would invalidate the sync state
// that describes the pair, so they are shown read-only.
CloudSyncDialog {
    id: dialog

    property var parentModal: null
    property string folderId: ""

    readonly property var folder: CloudSyncService.folderById(folderId) || ({})
    readonly property bool isStream: folder.mode === "stream"
    readonly property bool isTwoWay: folder.mode === "twoway"

    property string folderName: ""
    property int intervalSeconds: 900
    property bool realTime: false
    property string excludes: ""
    property string conflictResolve: "none"
    property bool confirmingRemove: false

    readonly property var conflictChoices: [
        {
            "value": "none",
            "label": I18n.tr("Keep both and ask me", "Conflict policy: keep both copies")
        },
        {
            "value": "newer",
            "label": I18n.tr("Keep the newer file", "Conflict policy: newest wins")
        },
        {
            "value": "larger",
            "label": I18n.tr("Keep the larger file", "Conflict policy: largest wins")
        },
        {
            "value": "path1",
            "label": I18n.tr("Always keep this computer's", "Conflict policy: local always wins")
        },
        {
            "value": "path2",
            "label": I18n.tr("Always keep the cloud's", "Conflict policy: remote always wins")
        }
    ]

    title: I18n.tr("Folder options", "Folder options dialog title")
    subtitle: folder.name || folder.localPath || ""
    confirmText: I18n.tr("Save", "Button that saves folder options")
    cancelText: I18n.tr("Cancel", "Button that discards folder option changes")
    dialogWidth: 560

    Component.onCompleted: {
        dialog.folderName = folder.name || "";
        dialog.intervalSeconds = folder.intervalSeconds || 0;
        dialog.realTime = folder.realTime === true;
        dialog.excludes = (folder.excludes || []).join(", ");
        dialog.conflictResolve = folder.conflictResolve || "none";
    }

    onCancelled: {
        if (dialog.parentModal)
            dialog.parentModal.closeDialog();
    }

    onConfirmed: {
        const excludeList = dialog.excludes.split(/[,\n]/).map(line => line.trim()).filter(line => line.length > 0);
        CloudSyncService.updateFolder({
            "id": dialog.folderId,
            "name": dialog.folderName,
            "intervalSeconds": dialog.isStream ? 0 : dialog.intervalSeconds,
            "realTime": dialog.isStream ? false : dialog.realTime,
            "excludes": excludeList,
            "conflictResolve": dialog.conflictResolve,
            "paused": folder.paused === true,
            "maxDelete": folder.maxDelete !== undefined ? folder.maxDelete : -1
        }, response => {
            if (response.error)
                return;
            if (dialog.parentModal)
                dialog.parentModal.closeDialog();
        });
    }

    // ---- Fixed facts ----
    CloudSyncRow {
        iconName: CloudIcons.modeIcon(dialog.folder.mode)
        iconColor: Theme.primary
        title: CloudSyncService.modeLabel(dialog.folder.mode)
        subtitle: (dialog.folder.localPath || "") + "  ⇄  " + CloudSyncService.accountLabelFor(dialog.folder.remote) + "/" + (dialog.folder.remotePath || "")
        subtitleElide: Text.ElideMiddle
    }

    StyledText {
        width: parent.width
        wrapMode: Text.WordWrap
        text: I18n.tr("How this folder syncs, and which folders it connects, cannot be changed. Remove it and add it again to change them.", "Explanation of the immutable folder fields")
        font.pixelSize: Theme.fontSizeSmall - 1
        color: Theme.surfaceVariantText
    }

    // ---- Name ----
    StyledText {
        width: parent.width
        text: I18n.tr("Folder name", "Field label for the display name of a synced folder")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceTextMedium
    }

    VgsTextField {
        width: parent.width
        text: dialog.folderName
        onTextEdited: dialog.folderName = text
    }

    // ---- Schedule ----
    CloudSyncDropdownRow {
        visible: !dialog.isStream
        text: I18n.tr("Sync schedule", "Setting label for how often a folder syncs")
        options: CloudIcons.intervalOptions(I18n.tr).map(opt => opt.label)
        currentValue: {
            const choices = CloudIcons.intervalOptions(I18n.tr);
            for (const opt of choices) {
                if (opt.value === dialog.intervalSeconds)
                    return opt.label;
            }
            return choices[0].label;
        }
        onValueChanged: value => {
            const choices = CloudIcons.intervalOptions(I18n.tr);
            for (const opt of choices) {
                if (opt.label === value) {
                    dialog.intervalSeconds = opt.value;
                    return;
                }
            }
        }
    }

    SettingsToggleRow {
        visible: !dialog.isStream
        text: I18n.tr("Sync as I work", "Setting label for the real-time watcher")
        description: I18n.tr("Watch this folder and sync a few seconds after you stop editing", "Setting description for the real-time watcher")
        checked: dialog.realTime
        onToggled: checked => dialog.realTime = checked
    }

    CloudSyncDropdownRow {
        visible: dialog.isTwoWay
        text: I18n.tr("When a file changes in both places", "Setting label for conflict policy")
        options: dialog.conflictChoices.map(choice => choice.label)
        currentValue: {
            for (const choice of dialog.conflictChoices) {
                if (choice.value === dialog.conflictResolve)
                    return choice.label;
            }
            return dialog.conflictChoices[0].label;
        }
        onValueChanged: value => {
            for (const choice of dialog.conflictChoices) {
                if (choice.label === value) {
                    dialog.conflictResolve = choice.value;
                    return;
                }
            }
        }
    }

    StyledText {
        visible: !dialog.isStream
        width: parent.width
        text: I18n.tr("Skip files matching", "Field label for exclude patterns")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceTextMedium
    }

    VgsTextField {
        visible: !dialog.isStream
        width: parent.width
        text: dialog.excludes
        placeholderText: "node_modules/**, *.tmp"
        onTextEdited: dialog.excludes = text
    }

    // ---- Two-way maintenance ----
    StyledText {
        visible: dialog.isTwoWay
        width: parent.width
        topPadding: Theme.spacingS
        text: I18n.tr("TWO-WAY BASELINE", "Section header for bisync resync controls")
        font.pixelSize: Theme.fontSizeSmall - 1
        font.weight: Font.DemiBold
        font.letterSpacing: 0.6
        color: Theme.surfaceVariantText
    }

    StyledText {
        visible: dialog.isTwoWay
        width: parent.width
        wrapMode: Text.WordWrap
        text: I18n.tr("If two-way sync gets confused — usually after a big move or a long time offline — rebuild the baseline by choosing which side wins once.", "Explanation of when to re-run a bisync resync")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    VgsButton {
        visible: dialog.isTwoWay
        text: I18n.tr("Rebuild baseline…", "Button that opens the resync dialog")
        iconName: "rule_settings"
        variant: "secondary"
        buttonHeight: 36
        onClicked: {
            if (dialog.parentModal)
                dialog.parentModal.openDialog("resync", {
                    "folderId": dialog.folderId
                });
        }
    }

    // ---- Remove ----
    StyledText {
        width: parent.width
        topPadding: Theme.spacingS
        text: I18n.tr("REMOVE", "Section header for removing a synced folder")
        font.pixelSize: Theme.fontSizeSmall - 1
        font.weight: Font.DemiBold
        font.letterSpacing: 0.6
        color: Theme.surfaceVariantText
    }

    StyledText {
        width: parent.width
        wrapMode: Text.WordWrap
        text: I18n.tr("Stops syncing this pair. Your files are left exactly where they are, on this computer and in the cloud.", "Reassurance shown next to the remove-folder action")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    VgsButton {
        text: dialog.confirmingRemove ? I18n.tr("Yes, stop syncing this folder", "Confirmation button for removing a synced folder") : I18n.tr("Stop syncing this folder", "Button that removes a synced folder")
        iconName: "link_off"
        variant: dialog.confirmingRemove ? "primary" : "secondary"
        backgroundColor: dialog.confirmingRemove ? Theme.error : Theme.buttonBg
        textColor: dialog.confirmingRemove ? Theme.background : Theme.surfaceText
        buttonHeight: 36
        onClicked: {
            if (!dialog.confirmingRemove) {
                dialog.confirmingRemove = true;
                return;
            }
            CloudSyncService.removeFolder(dialog.folderId, null);
            if (dialog.parentModal)
                dialog.parentModal.closeDialog();
        }
    }
}
