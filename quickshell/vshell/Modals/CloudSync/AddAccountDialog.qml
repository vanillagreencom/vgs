import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets
import "CloudSyncIcons.js" as CloudIcons

// Two-step account setup: choose a service, then either sign in through the
// browser (OAuth providers) or fill in the credentials rclone needs.
CloudSyncDialog {
    id: dialog

    property var parentModal: null

    property int step: 0
    property var providers: []
    property bool loading: true
    property string loadError: ""
    property bool showAll: false
    property var selectedProvider: null
    property string accountName: ""
    property bool showAdvanced: false
    property bool browserOpened: false
    readonly property bool oauthFailed: dialog.step === 2 && !CloudSyncService.oauthActive && CloudSyncService.oauthError.length > 0

    // Values typed into the generated credential form, keyed by option name.
    property var fieldValues: ({})

    readonly property bool isOAuth: selectedProvider !== null && selectedProvider.oauth === true

    // Expose only required credential fields initially; optional fields remain under Advanced.
    readonly property var visibleOptions: {
        if (!selectedProvider)
            return [];
        const all = selectedProvider.options || [];
        if (dialog.showAdvanced)
            return all;
        if (dialog.isOAuth)
            return [];
        return all.filter(opt => opt.required);
    }

    readonly property bool hasHiddenOptions: selectedProvider !== null && (selectedProvider.options || []).length > dialog.visibleOptions.length

    readonly property bool nameValid: /^[A-Za-z0-9_.\-]{1,40}$/.test(dialog.accountName)

    readonly property bool requiredFilled: {
        if (!selectedProvider)
            return false;
        for (const opt of (selectedProvider.options || [])) {
            if (!opt.required)
                continue;
            const value = dialog.fieldValues[opt.name];
            if (!value || String(value).length === 0)
                return false;
        }
        return true;
    }

    title: {
        if (step === 0)
            return I18n.tr("Add a cloud account", "Add-account dialog title, provider step");
        const provider = selectedProvider ? selectedProvider.name : "";
        if (step === 2)
            return I18n.tr("Waiting for sign-in", "Add-account dialog title while the browser flow runs");
        return I18n.tr("Connect to", "Add-account dialog title prefix, details step") + " " + provider;
    }
    subtitle: {
        if (step === 0)
            return I18n.tr("Pick the service your files live on.", "Add-account dialog subtitle, provider step");
        if (step === 2)
            return I18n.tr("Finish signing in in your browser. This closes itself when the account is connected.", "Add-account dialog subtitle while the browser flow runs");
        return dialog.isOAuth ? I18n.tr("Give the account a name, then sign in.", "Add-account dialog subtitle for OAuth providers") : I18n.tr("Give the account a name and enter its sign-in details.", "Add-account dialog subtitle for credential providers");
    }

    showConfirm: step === 1
    confirmText: dialog.isOAuth ? I18n.tr("Sign in", "Confirm button for an OAuth account") : I18n.tr("Connect", "Confirm button for a credentials account")
    confirmEnabled: step === 1 && nameValid && (dialog.isOAuth || requiredFilled)
    cancelText: step === 1 ? I18n.tr("Back", "Button that returns to the provider list") : I18n.tr("Cancel", "Button that closes the add-account dialog")

    dialogWidth: 560

    onCancelled: {
        if (step === 2) {
            CloudSyncService.cancelOAuth(null);
            dialog.step = 1;
            return;
        }
        if (step === 1) {
            step = 0;
            selectedProvider = null;
            return;
        }
        if (dialog.parentModal)
            dialog.parentModal.closeDialog();
    }

    onConfirmed: {
        if (!selectedProvider)
            return;
        const params = {};
        for (const key in dialog.fieldValues) {
            const value = dialog.fieldValues[key];
            if (value !== undefined && String(value).length > 0)
                params[key] = String(value);
        }
        if (dialog.isOAuth) {
            // Keep the sign-in dialog open while the backend works so progress stays visible.
            dialog.browserOpened = false;
            dialog.step = 2;
            CloudSyncService.startOAuth(dialog.accountName, selectedProvider.type, params, null);
            return;
        }
        CloudSyncService.addRemote(dialog.accountName, selectedProvider.type, params, null);
        if (dialog.parentModal)
            dialog.parentModal.closeDialog();
    }

    // The dialog can open before the capability handshake finishes, so the
    // provider list waits for the service instead of failing once and giving up.
    Component.onCompleted: dialog.loadProviders()

    Connections {
        target: CloudSyncService

        function onAvailableChanged() {
            if (CloudSyncService.available && dialog.providers.length === 0)
                dialog.loadProviders();
        }


        function onOauthChanged() {
            if (dialog.step !== 2 || dialog.browserOpened)
                return;
            const url = CloudSyncService.oauthUrl;
            if (!url || url.length === 0)
                return;
            dialog.browserOpened = true;
            Quickshell.execDetached([Paths.vshellCli, "open", url]);
        }

        // A reported account confirms completion; close the waiting dialog when it arrives.
        function onAccountsChanged() {
            if (dialog.step !== 2)
                return;
            if (!CloudSyncService.accountByName(dialog.accountName))
                return;
            if (dialog.parentModal)
                dialog.parentModal.closeDialog();
        }
    }

    function loadProviders() {
        if (!CloudSyncService.available) {
            dialog.loading = true;
            return;
        }
        dialog.loading = true;
        dialog.loadError = "";
        CloudSyncService.listProviders(response => {
            dialog.loading = false;
            if (response.error) {
                dialog.loadError = response.error;
                return;
            }
            dialog.providers = (response.result && response.result.providers) || [];
        });
    }

    function selectProvider(provider) {
        dialog.selectedProvider = provider;
        dialog.fieldValues = {};
        dialog.showAdvanced = false;

        dialog.accountName = suggestName(provider.type);
        dialog.step = 1;
    }

    function suggestName(type) {
        const base = String(type || "cloud").replace(/[^A-Za-z0-9]/g, "");
        const taken = CloudSyncService.accounts.map(a => a.name);
        if (taken.indexOf(base) < 0)
            return base;
        for (var i = 2; i < 50; i++) {
            if (taken.indexOf(base + i) < 0)
                return base + i;
        }
        return base;
    }

    function setField(name, value) {
        const copy = Object.assign({}, dialog.fieldValues);
        copy[name] = value;
        dialog.fieldValues = copy;
    }



    Item {
        width: parent.width
        height: 60
        visible: dialog.step === 0 && dialog.loading

        VgsSpinner {
            anchors.centerIn: parent
            size: 28
        }
    }

    StyledText {
        visible: dialog.step === 0 && dialog.loadError.length > 0
        width: parent.width
        wrapMode: Text.WordWrap
        text: dialog.loadError
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.error
    }

    Repeater {
        model: dialog.step === 0 && !dialog.loading ? dialog.providers.filter(p => dialog.showAll || p.featured) : []

        CloudSyncRow {
            required property var modelData

            tile: true
            iconName: CloudIcons.providerIcon(modelData.type)
            iconColor: Theme.primary
            interactive: true
            title: modelData.name
            subtitle: modelData.oauth ? I18n.tr("Sign in with your browser", "Provider tile hint for OAuth backends") : I18n.tr("Needs credentials", "Provider tile hint for credential backends")

            trailing: [
                VgsIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron_right"
                    size: Theme.iconSizeSmall
                    color: Theme.surfaceVariantText
                }
            ]

            onClicked: dialog.selectProvider(modelData)
        }
    }

    VgsButton {
        visible: dialog.step === 0 && !dialog.loading
        text: dialog.showAll ? I18n.tr("Show popular services only", "Button that collapses the full provider list") : I18n.tr("Show all services", "Button that expands the full provider list")
        iconName: dialog.showAll ? "expand_less" : "expand_more"
        variant: "secondary"
        buttonHeight: 36
        onClicked: dialog.showAll = !dialog.showAll
    }

    // OAuth uses the registered application by default. Show custom application options under Advanced.

    Column {
        visible: dialog.step === 1
        width: parent.width
        spacing: Theme.spacingXS

        StyledText {
            width: parent.width
            text: I18n.tr("Account name", "Field label for the rclone remote name")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceTextMedium
        }

        VgsTextField {
            width: parent.width
            text: dialog.accountName
            placeholderText: I18n.tr("For example: work-drive", "Placeholder for the account name field")
            onTextEdited: dialog.accountName = text
        }

        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: dialog.accountName.length > 0 && !dialog.nameValid ? I18n.tr("Use letters, numbers, dots, dashes and underscores only.", "Validation message for the account name field") : I18n.tr("What this account is called inside Cloud Sync. Only you see it.", "Help text for the account name field")
            font.pixelSize: Theme.fontSizeSmall - 1
            color: dialog.accountName.length > 0 && !dialog.nameValid ? Theme.error : Theme.surfaceVariantText
        }
    }


    CloudSyncRow {
        visible: dialog.step === 1 && dialog.isOAuth
        iconName: "open_in_browser"
        iconColor: Theme.primary
        iconSize: Theme.iconSize
        title: I18n.tr("Sign in with your browser", "Heading of the OAuth explainer in the add-account dialog")
        subtitle: I18n.tr("Choosing Sign in opens %1 in your browser. Cloud Sync never sees your password — it stores only the access token the service hands back.", "Body of the OAuth explainer").arg(dialog.selectedProvider ? dialog.selectedProvider.name : "")
        subtitleWrap: true
    }


    Repeater {
        model: dialog.step === 1 ? dialog.visibleOptions : []

        Column {
            required property var modelData

            width: parent.width
            spacing: Theme.spacingXS

            // Boolean options use a labeled toggle; omit a separate label for that branch.
            StyledText {
                visible: modelData.type !== "bool"
                width: parent.width
                text: modelData.label || modelData.name
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceTextMedium
            }

            SettingsToggleRow {
                visible: modelData.type === "bool"
                width: parent.width
                text: modelData.label || modelData.name
                description: modelData.help || ""
                checked: (dialog.fieldValues[modelData.name] || modelData.default) === "true"
                onToggled: checked => dialog.setField(modelData.name, checked ? "true" : "false")
            }

            VgsTextField {
                visible: modelData.type !== "bool"
                width: parent.width
                text: dialog.fieldValues[modelData.name] || ""
                placeholderText: modelData.default || ""
                echoMode: modelData.isPassword ? TextInput.Password : TextInput.Normal
                showPasswordToggle: modelData.isPassword
                onTextEdited: dialog.setField(modelData.name, text)
            }

            StyledText {
                visible: modelData.type !== "bool" && (modelData.help || "").length > 0
                width: parent.width
                text: modelData.help
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }
        }
    }


    Row {
        visible: dialog.step === 1 && dialog.hasHiddenOptions
        width: parent.width
        spacing: Theme.spacingS

        VgsButton {
            text: dialog.showAdvanced ? I18n.tr("Hide advanced options", "Button that collapses advanced provider options") : I18n.tr("Advanced options", "Button that expands advanced provider options")
            iconName: dialog.showAdvanced ? "expand_less" : "expand_more"
            variant: "secondary"
            buttonHeight: 36
            onClicked: dialog.showAdvanced = !dialog.showAdvanced
        }

        VgsButton {
            visible: dialog.selectedProvider && (dialog.selectedProvider.docsUrl || "").length > 0
            text: I18n.tr("Setup guide", "Button opening rclone's documentation for this provider")
            iconName: "open_in_new"
            variant: "secondary"
            buttonHeight: 36
            onClicked: Quickshell.execDetached([Paths.vshellCli, "open", dialog.selectedProvider.docsUrl])
        }
    }

    StyledText {
        visible: dialog.step === 1 && dialog.showAdvanced && dialog.isOAuth
        width: parent.width
        wrapMode: Text.WordWrap
        text: I18n.tr("You do not need any of these to sign in. Supply your own Client ID and Secret only if you want this computer to use your own API quota instead of rclone's shared one — the setup guide explains how to create them.", "Explanation shown above advanced OAuth options")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }



    CloudSyncRow {
        visible: dialog.step === 2
        iconName: "open_in_browser"
        iconColor: Theme.primary
        iconSize: Theme.iconSize
        title: dialog.oauthFailed ? I18n.tr("Sign-in did not finish", "Heading when the browser flow failed") : I18n.tr("Waiting for your browser", "Heading while the browser flow runs")
        subtitle: dialog.oauthFailed ? CloudSyncService.oauthError : I18n.tr("Approve access to %1, then come back. This closes itself once the account is connected.", "Body while the browser flow runs").arg(dialog.selectedProvider ? dialog.selectedProvider.name : "")
        subtitleWrap: true
        subtitleColor: dialog.oauthFailed ? Theme.error : Theme.surfaceVariantText

        trailing: [
            VgsSpinner {
                anchors.verticalCenter: parent.verticalCenter
                visible: !dialog.oauthFailed
                size: 20
            }
        ]
    }

    StyledText {
        visible: dialog.step === 2 && !dialog.oauthFailed && CloudSyncService.oauthUrl.length > 0
        width: parent.width
        text: I18n.tr("If your browser did not open, use this link:", "Label above the manual sign-in link")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceTextMedium
    }

    StyledRect {
        visible: dialog.step === 2 && !dialog.oauthFailed && CloudSyncService.oauthUrl.length > 0
        width: parent.width
        height: 40
        radius: Theme.controlRadius
        color: Theme.elevatedRowColor

        StyledText {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingM
            verticalAlignment: Text.AlignVCenter
            text: CloudSyncService.oauthUrl
            elide: Text.ElideRight
            wrapMode: Text.NoWrap
            maximumLineCount: 1
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceTextMedium
        }
    }

    Row {
        visible: dialog.step === 2
        width: parent.width
        spacing: Theme.spacingS

        VgsButton {
            visible: !dialog.oauthFailed
            text: I18n.tr("Open in browser", "Button that opens the pending sign-in URL")
            iconName: "open_in_new"
            variant: "secondary"
            buttonHeight: 36
            enabled: CloudSyncService.oauthUrl.length > 0
            onClicked: Quickshell.execDetached([Paths.vshellCli, "open", CloudSyncService.oauthUrl])
        }

        VgsButton {
            visible: !dialog.oauthFailed
            text: I18n.tr("Copy link", "Button that copies the pending sign-in URL")
            iconName: "content_copy"
            variant: "secondary"
            buttonHeight: 36
            enabled: CloudSyncService.oauthUrl.length > 0
            onClicked: {
                Quickshell.execDetached([Paths.vshellCli, "cl", "copy", CloudSyncService.oauthUrl]);
                ToastService.showInfo(I18n.tr("Sign-in link copied", "Toast after copying the OAuth URL"));
            }
        }

        VgsButton {
            visible: dialog.oauthFailed
            text: I18n.tr("Try again", "Button that restarts a failed sign-in")
            iconName: "refresh"
            buttonHeight: 36
            backgroundColor: Theme.primary
            textColor: Theme.primaryText
            onClicked: dialog.step = 1
        }
    }
}
