pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "CloudSyncIcons.js" as CloudIcons

// Confirms disconnecting an account.
//
// This is the most destructive thing in the app, and its blast radius is not
// obvious: the account's credentials go away, so every folder that syncs
// through it stops working. Those folders are listed by name and removed with
// the account rather than left behind pointing at a remote that no longer
// exists. Files on this computer are never touched, which is the fact people
// most need stated out loud before they press the red button.
CloudSyncDialog {
    id: dialog

    property var parentModal: null
    property string account: ""

    readonly property var accountData: CloudSyncService.accountByName(account) || ({})
    readonly property var affected: CloudSyncService.foldersForAccount(account)
    readonly property bool hasFolders: affected.length > 0

    // Typing the account's name is required only when folders would be removed;
    // a bare confirm is enough when nothing is at stake.
    property string typed: ""
    readonly property string expected: CloudSyncService.accountName(accountData)
    readonly property bool acknowledged: !hasFolders || typed.trim().toLowerCase() === expected.trim().toLowerCase()

    title: I18n.tr("Disconnect this account?", "Disconnect account dialog title")
    subtitle: dialog.hasFolders ? I18n.tr("This account signs in for folders that are syncing right now.", "Disconnect account dialog subtitle when folders are affected") : I18n.tr("Nothing on this computer syncs through this account.", "Disconnect account dialog subtitle when no folders are affected")
    confirmText: I18n.tr("Disconnect", "Button that confirms removing a cloud account")
    confirmDestructive: true
    confirmEnabled: dialog.acknowledged
    dialogWidth: 520

    onCancelled: {
        if (dialog.parentModal)
            dialog.parentModal.closeDialog();
    }

    onConfirmed: {
        if (!dialog.acknowledged)
            return;
        CloudSyncService.removeRemote(dialog.account, dialog.hasFolders, response => {
            if (response.error)
                return; // the service already surfaced it; keep the dialog open
            if (dialog.parentModal)
                dialog.parentModal.closeDialog();
        });
    }

    // A dialog whose subject vanished (disconnected elsewhere, or removed with
    // the rclone CLI) describes nothing. Disconnect is the one that matters:
    // with no account, hasFolders goes false, the type-to-confirm rail hides
    // and the destructive button silently enables.
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

    // ---- What goes away ----
    Column {
        width: parent.width
        spacing: Theme.spacingXS
        visible: dialog.hasFolders

        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: dialog.affected.length === 1 ? I18n.tr("This synced folder will be removed:", "Header above the single folder lost by disconnecting an account") : I18n.tr("These synced folders will be removed:", "Header above the folders lost by disconnecting an account")
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.error
        }

        Repeater {
            model: dialog.affected

            CloudSyncRow {
                required property var modelData

                iconName: CloudIcons.modeIcon(modelData.mode)
                iconColor: Theme.surfaceVariantText
                title: modelData.name || modelData.localPath
                subtitle: modelData.localPath
                subtitleElide: Text.ElideMiddle
            }
        }
    }

    StyledText {
        width: parent.width
        wrapMode: Text.WordWrap
        lineHeight: 1.35
        lineHeightMode: Text.ProportionalHeight
        text: dialog.hasFolders ? I18n.tr("Your files stay exactly where they are, both on this computer and in the cloud. Only the connection and the sync settings are removed — you can add the account again later and set the folders up afresh.", "Reassurance shown before disconnecting an account with folders") : I18n.tr("Your files stay exactly where they are, both on this computer and in the cloud. Only the connection is removed.", "Reassurance shown before disconnecting an account with no folders")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    // ---- Deliberate confirmation ----
    Column {
        width: parent.width
        spacing: Theme.spacingXS
        visible: dialog.hasFolders

        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: I18n.tr("Type", "Precedes the account name a user must type to confirm") + " " + dialog.expected + " " + I18n.tr("to confirm", "Follows the account name a user must type to confirm")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceTextMedium
        }

        VgsTextField {
            width: parent.width
            text: dialog.typed
            placeholderText: dialog.expected
            onTextEdited: dialog.typed = text
        }
    }
}
