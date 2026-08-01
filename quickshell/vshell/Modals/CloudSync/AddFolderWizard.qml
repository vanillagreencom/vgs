import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets
import "CloudSyncIcons.js" as CloudIcons

// Add-folder flow. The sync mode is deliberately unset until the user picks
// one: the four modes behave very differently and a default would quietly make
// that decision for them.
CloudSyncDialog {
    id: wizard

    property var parentModal: null
    // Set when the wizard is opened from one account's card: the account is
    // already chosen, so asking again would be a step that answers itself.
    property string presetAccount: ""

    readonly property int firstStep: wizard.presetAccount.length > 0 ? 1 : 0

    property int step: wizard.firstStep
    property string account: wizard.presetAccount.length > 0 ? wizard.presetAccount : (CloudSyncService.accounts.length === 1 ? CloudSyncService.accounts[0].name : "")
    property string mode: ""
    property string remotePath: ""
    property string localPath: ""
    property string folderName: ""
    property int intervalSeconds: 900
    property bool realTime: false
    property string excludes: ""

    readonly property bool isStream: mode === "stream"
    readonly property int lastStep: 4

    readonly property var modeChoices: [
        {
            "id": "twoway",
            "requiresFuse": false
        },
        {
            "id": "backup",
            "requiresFuse": false
        },
        {
            "id": "restore",
            "requiresFuse": false
        },
        {
            "id": "stream",
            "requiresFuse": true
        }
    ]

    readonly property bool stepComplete: {
        switch (wizard.step) {
        case 0:
            return wizard.account.length > 0;
        case 1:
            return wizard.mode.length > 0;
        case 2:
            return true; // the remote root is a legitimate choice
        case 3:
            return wizard.isStream ? wizard.folderName.length > 0 : wizard.localPath.length > 0;
        case 4:
            return true;
        }
        return false;
    }

    dialogWidth: 600
    maxDialogHeight: 700

    title: {
        switch (wizard.step) {
        case 0:
            return I18n.tr("Which account?", "Add-folder wizard step title: account");
        case 1:
            return I18n.tr("How should this folder sync?", "Add-folder wizard step title: mode");
        case 2:
            return I18n.tr("Which cloud folder?", "Add-folder wizard step title: remote folder");
        case 3:
            return wizard.isStream ? I18n.tr("What should it be called?", "Add-folder wizard step title: mount name") : I18n.tr("Which folder on this computer?", "Add-folder wizard step title: local folder");
        }
        return I18n.tr("When should it sync?", "Add-folder wizard step title: schedule");
    }

    subtitle: {
        switch (wizard.step) {
        case 1:
            return I18n.tr("There is no default — each option behaves differently.", "Add-folder wizard subtitle for the mode step");
        case 2:
            return I18n.tr("Open a folder to go into it. The folder you are looking at is the one that gets synced.", "Add-folder wizard subtitle for the remote folder step");
        case 3:
            return wizard.isStream ? I18n.tr("Streamed folders appear under your Cloud Sync directory.", "Add-folder wizard subtitle for naming a mount") : I18n.tr("Open a folder to go into it. The folder you are looking at is the one that gets synced.", "Add-folder wizard subtitle for the local folder step");
        }
        return "";
    }

    confirmText: wizard.step === wizard.lastStep ? I18n.tr("Add folder", "Final confirm button in the add-folder wizard") : I18n.tr("Next", "Button advancing the add-folder wizard")
    cancelText: wizard.step === wizard.firstStep ? I18n.tr("Cancel", "Button closing the add-folder wizard") : I18n.tr("Back", "Button returning to the previous wizard step")
    confirmEnabled: wizard.stepComplete

    onCancelled: {
        if (wizard.step === wizard.firstStep) {
            if (wizard.parentModal)
                wizard.parentModal.closeDialog();
            return;
        }
        wizard.step = wizard.step - 1;
    }

    onConfirmed: {
        if (wizard.step < wizard.lastStep) {
            wizard.step = wizard.step + 1;
            return;
        }
        const excludeList = wizard.excludes.split(/[,\n]/).map(line => line.trim()).filter(line => line.length > 0);
        CloudSyncService.addFolder({
            "name": wizard.folderName,
            "remote": wizard.account,
            "remotePath": wizard.remotePath,
            "localPath": wizard.localPath,
            "mode": wizard.mode,
            "intervalSeconds": wizard.isStream ? 0 : wizard.intervalSeconds,
            "realTime": wizard.isStream ? false : wizard.realTime,
            "excludes": excludeList
        }, response => {
            if (response.error)
                return; // the service already surfaced it; keep the wizard open
            if (wizard.parentModal)
                wizard.parentModal.closeDialog();
        });
    }

    // ---- Step 0: account ----
    Repeater {
        model: wizard.step === 0 ? CloudSyncService.accounts : []

        CloudSyncRow {
            required property var modelData

            tile: true
            iconName: CloudIcons.providerIcon(modelData.type)
            iconColor: Theme.primary
            interactive: true
            selected: wizard.account === modelData.name
            title: CloudSyncService.accountName(modelData)
            subtitle: CloudSyncService.accountDetail(modelData)

            trailing: [
                VgsIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: wizard.account === modelData.name
                    name: "check_circle"
                    size: Theme.iconSizeSmall
                    color: Theme.primary
                }
            ]

            onClicked: wizard.account = modelData.name
        }
    }

    // ---- Step 1: mode ----
    Repeater {
        model: wizard.step === 1 ? wizard.modeChoices : []

        CloudSyncRow {
            required property var modelData

            readonly property bool unavailable: modelData.requiresFuse && !CloudSyncService.canMount

            iconName: CloudIcons.modeIcon(modelData.id)
            iconColor: selected ? Theme.primary : Theme.surfaceVariantText
            iconSize: Theme.iconSize
            interactive: !unavailable
            selected: wizard.mode === modelData.id
            opacity: unavailable ? 0.4 : 1
            title: CloudSyncService.modeLabel(modelData.id)
            subtitle: CloudSyncService.modeDescription(modelData.id)
            subtitleWrap: true

            body: [
                StyledText {
                    width: parent.width
                    visible: modelData.requiresFuse && !CloudSyncService.canMount
                    text: I18n.tr("Needs fuse3 installed.", "Reason a streamed folder cannot be created")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.warning
                }
            ]

            onClicked: wizard.mode = modelData.id
        }
    }

    StyledText {
        visible: wizard.step === 1 && wizard.mode === "twoway"
        width: parent.width
        wrapMode: Text.WordWrap
        text: I18n.tr("Two-way folders need a starting point before their first sync. You will be asked which side wins once the folder is created.", "Warning shown when two-way sync is selected")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.warning
    }

    // ---- Step 2: cloud folder ----
    RemoteFolderPicker {
        id: remotePicker

        visible: wizard.step === 2
        width: parent.width
        height: 300
        remote: wizard.account
        onCurrentPathChanged: wizard.remotePath = currentPath
    }

    // ---- Step 3: local folder or mount name ----
    LocalFolderPicker {
        id: localPicker

        visible: wizard.step === 3 && !wizard.isStream
        width: parent.width
        height: 300
        onCurrentPathChanged: {
            wizard.localPath = currentPath;
            if (wizard.folderName.length === 0)
                wizard.folderName = currentPath.split("/").pop();
        }
    }

    StyledText {
        visible: wizard.step === 3
        width: parent.width
        text: I18n.tr("Folder name", "Field label for the display name of a synced folder")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceTextMedium
    }

    VgsTextField {
        visible: wizard.step === 3
        width: parent.width
        text: wizard.folderName
        placeholderText: I18n.tr("For example: Documents", "Placeholder for the folder name field")
        onTextEdited: wizard.folderName = text
    }

    // ---- Step 4: schedule and filters ----
    CloudSyncDropdownRow {
        visible: wizard.step === 4 && !wizard.isStream
        text: I18n.tr("Sync schedule", "Setting label for how often a folder syncs")
        options: CloudIcons.intervalOptions(I18n.tr).map(opt => opt.label)
        currentValue: {
            const choices = CloudIcons.intervalOptions(I18n.tr);
            for (const opt of choices) {
                if (opt.value === wizard.intervalSeconds)
                    return opt.label;
            }
            return choices[2].label;
        }
        onValueChanged: value => {
            const choices = CloudIcons.intervalOptions(I18n.tr);
            for (const opt of choices) {
                if (opt.label === value) {
                    wizard.intervalSeconds = opt.value;
                    return;
                }
            }
        }
    }

    SettingsToggleRow {
        visible: wizard.step === 4 && !wizard.isStream
        text: I18n.tr("Sync as I work", "Setting label for the real-time watcher")
        description: I18n.tr("Watch this folder and sync a few seconds after you stop editing. Uses more battery and network on large folders.", "Setting description for the real-time watcher")
        checked: wizard.realTime
        onToggled: checked => wizard.realTime = checked
    }

    StyledText {
        visible: wizard.step === 4 && !wizard.isStream
        width: parent.width
        text: I18n.tr("Skip files matching", "Field label for exclude patterns")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceTextMedium
    }

    VgsTextField {
        visible: wizard.step === 4 && !wizard.isStream
        width: parent.width
        text: wizard.excludes
        placeholderText: "node_modules/**, *.tmp"
        onTextEdited: wizard.excludes = text
    }

    StyledText {
        visible: wizard.step === 4 && !wizard.isStream
        width: parent.width
        wrapMode: Text.WordWrap
        text: I18n.tr("Separate patterns with commas. Patterns use rclone filter syntax.", "Help text for exclude patterns")
        font.pixelSize: Theme.fontSizeSmall - 1
        color: Theme.surfaceVariantText
    }

    StyledText {
        visible: wizard.step === 4 && wizard.isStream
        width: parent.width
        wrapMode: Text.WordWrap
        text: I18n.tr("Streamed folders have no schedule — files download when you open them, and changes upload as you save. Nothing is stored on this computer beyond a cache.", "Explanation shown instead of schedule options for streamed folders")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    // ---- Running summary, visible from the cloud-folder step onward ----
    CloudSyncRow {
        visible: wizard.step >= 2
        iconName: CloudIcons.modeIcon(wizard.mode)
        iconColor: Theme.primary
        title: CloudSyncService.modeLabel(wizard.mode)
        subtitle: (wizard.isStream ? I18n.tr("Appears as", "Summary label for a streamed folder's mount name") + ": " + (wizard.folderName || "…") : (wizard.localPath || I18n.tr("Choose a local folder", "Summary placeholder before a local folder is chosen"))) + "  ⇄  " + wizard.account + ":" + wizard.remotePath
        subtitleElide: Text.ElideMiddle
    }
}
