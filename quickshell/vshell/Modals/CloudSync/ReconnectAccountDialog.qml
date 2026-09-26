pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "CloudSyncIcons.js" as CloudIcons

// Refresh an account token without changing the remote name that its folders reference.
CloudSyncDialog {
    id: dialog

    property var parentModal: null
    property string account: ""

    readonly property var accountData: CloudSyncService.accountByName(account) || ({})
    readonly property var affected: CloudSyncService.foldersForAccount(account)
    // Reconnect must use the account's custom application credentials. Prefill the stored ID; the secret must be entered again.
    readonly property bool customCredentials: (accountData.clientId || "").length > 0

    property string clientId: ""
    property string clientSecret: ""

    title: I18n.tr("Sign in again", "Reconnect account dialog title")
    subtitle: I18n.tr("Opens your browser so this account can be authorized again. Your synced folders are kept.", "Reconnect account dialog subtitle")
    confirmText: I18n.tr("Open browser", "Button that starts the reconnect sign-in")
    confirmEnabled: CloudSyncService.daemonRunning && !CloudSyncService.oauthActive
    dialogWidth: 520

    Component.onCompleted: {
        dialog.clientId = dialog.accountData.clientId || "";
    }

    onCancelled: {
        if (dialog.parentModal)
            dialog.parentModal.closeDialog();
    }

    onConfirmed: {
        const params = {};
        if (dialog.customCredentials) {
            if (dialog.clientId.trim().length > 0)
                params["client_id"] = dialog.clientId.trim();
            if (dialog.clientSecret.trim().length > 0)
                params["client_secret"] = dialog.clientSecret.trim();
        }
        CloudSyncService.reconnectRemote(dialog.account, params, response => {
            if (response.error)
                return; // The service reports failures; keep this dialog open. AccountsPage tracks the subsequent browser sign-in.
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
        wrapMode: Text.WordWrap
        lineHeight: 1.35
        lineHeightMode: Text.ProportionalHeight
        text: dialog.affected.length === 0 ? I18n.tr("Nothing else changes: the account keeps its name and settings.", "Explanation of reconnect when no folders use the account") : (dialog.affected.length === 1 ? I18n.tr("The folder syncing through this account keeps working — nothing has to be set up again.", "Explanation of reconnect with one folder") : dialog.affected.length + " " + I18n.tr("folders sync through this account and all of them keep working — nothing has to be set up again.", "Explanation of reconnect with several folders"))
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    // ---- Own API credentials ----
    Column {
        width: parent.width
        spacing: Theme.spacingXS
        visible: dialog.customCredentials

        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: I18n.tr("This account uses your own API credentials. Enter the secret again to sign in with them; leave it empty to sign in with the built-in credentials instead.", "Help text above the credential fields on the reconnect dialog")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        StyledText {
            width: parent.width
            text: I18n.tr("Client ID", "Field label for an OAuth client ID")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceTextMedium
        }

        VgsTextField {
            width: parent.width
            text: dialog.clientId
            onTextEdited: dialog.clientId = text
        }

        StyledText {
            width: parent.width
            text: I18n.tr("Client secret", "Field label for an OAuth client secret")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceTextMedium
        }

        VgsTextField {
            width: parent.width
            echoMode: TextInput.Password
            text: dialog.clientSecret
            onTextEdited: dialog.clientSecret = text
        }
    }

    StyledText {
        width: parent.width
        visible: !CloudSyncService.oauthActive && CloudSyncService.daemonRunning === false
        wrapMode: Text.WordWrap
        text: I18n.tr("The sync engine is not running, so signing in is not possible right now.", "Blocker shown on the reconnect dialog when rclone is down")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.warning
    }

    StyledText {
        width: parent.width
        visible: CloudSyncService.oauthActive
        wrapMode: Text.WordWrap
        text: I18n.tr("Another sign-in is already in progress. Finish or cancel it first.", "Blocker shown on the reconnect dialog during another sign-in")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.warning
    }
}
