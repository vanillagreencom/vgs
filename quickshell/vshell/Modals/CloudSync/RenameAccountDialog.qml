pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "CloudSyncIcons.js" as CloudIcons

// Change the display label while preserving the remote name used by configured folders.
CloudSyncDialog {
    id: dialog

    property var parentModal: null
    property string account: ""

    readonly property var accountData: CloudSyncService.accountByName(account) || ({})
    property string label: ""

    title: I18n.tr("Rename account", "Rename account dialog title")
    subtitle: I18n.tr("Only changes what this account is called here. Your files and folders are untouched.", "Rename account dialog subtitle")
    confirmText: I18n.tr("Save", "Button that saves an account name")
    dialogWidth: 480

    Component.onCompleted: {
        dialog.label = dialog.accountData.label || "";
        nameField.forceActiveFocus();
    }

    onCancelled: {
        if (dialog.parentModal)
            dialog.parentModal.closeDialog();
    }

    onConfirmed: {
        CloudSyncService.updateRemote(dialog.account, dialog.label, response => {
            if (response.error)
                return; // the service already surfaced it; keep the dialog open
            if (dialog.parentModal)
                dialog.parentModal.closeDialog();
        });
    }

    // Closes rather than rendering an empty identity row if the account is
    // removed elsewhere while this dialog is open.
    Connections {
        target: CloudSyncService

        function onAccountsChanged() {
            if (CloudSyncService.accountByName(dialog.account) === null && dialog.parentModal)
                dialog.parentModal.closeDialog();
        }
    }

    CloudSyncRow {
        tile: true
        iconName: CloudIcons.providerIcon(dialog.accountData.type)
        iconColor: Theme.primary
        title: CloudSyncService.accountName(dialog.accountData)
        subtitle: CloudSyncService.accountDetail(dialog.accountData)
    }

    StyledText {
        width: parent.width
        text: I18n.tr("Display name", "Field label for a cloud account's display name")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceTextMedium
    }

    VgsTextField {
        id: nameField

        width: parent.width
        text: dialog.label
        placeholderText: dialog.accountData.provider || dialog.account
        onTextEdited: dialog.label = text
        onAccepted: dialog.confirmed()
    }

    StyledText {
        width: parent.width
        wrapMode: Text.WordWrap
        text: I18n.tr("Leave this empty to use the service name.", "Help text under the account display name field")
        font.pixelSize: Theme.fontSizeSmall - 1
        color: Theme.surfaceVariantText
    }
}
