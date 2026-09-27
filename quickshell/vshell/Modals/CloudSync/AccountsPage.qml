pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "CloudSyncIcons.js" as CloudIcons

// Account cards group identity, health, storage and the folders that use that account.
CloudSyncPage {
    id: page

    title: I18n.tr("Accounts", "Cloud Sync accounts page title")
    subtitle: I18n.tr("Cloud services this computer can sync with.", "Cloud Sync accounts page subtitle")

    // Keep expansion as state rather than a binding so account broadcasts do not collapse the card being read.
    property string expandedAccount: ""
    property bool autoExpanded: false

    function autoExpandSingleAccount() {
        if (page.autoExpanded)
            return;
        if (CloudSyncService.accounts.length !== 1)
            return;
        page.autoExpanded = true;
        page.expandedAccount = CloudSyncService.accounts[0].name;
    }

    Component.onCompleted: page.autoExpandSingleAccount()

    Connections {
        target: CloudSyncService

        function onAccountsChanged() {
            // State can arrive a frame after the page is built, so the initial
            // expansion is attempted again — once — when it does.
            page.autoExpandSingleAccount();
            if (page.expandedAccount.length > 0 && CloudSyncService.accountByName(page.expandedAccount) === null)
                page.expandedAccount = "";
        }
    }

    headerAction: [
        VgsButton {
            text: I18n.tr("Add account", "Button that starts connecting a new cloud account")
            iconName: "add"
            buttonHeight: 36
            backgroundColor: Theme.primary
            textColor: Theme.primaryText
            enabled: CloudSyncService.daemonRunning && !CloudSyncService.oauthActive
            onClicked: page.parentModal.openDialog("addAccount", {})
        }
    ]


    CloudSyncCard {
        visible: CloudSyncService.oauthActive
        iconName: "hourglass_top"
        title: CloudSyncService.oauthReconnect ? I18n.tr("Signing in again", "Card title while an existing account is being reconnected") : I18n.tr("Waiting for sign-in", "Card title while a browser OAuth flow is running")
        description: I18n.tr("Finish signing in the browser window that just opened. If nothing opened, use the link below.", "Card body while a browser OAuth flow is running")

        CloudSyncRow {
            title: CloudSyncService.oauthUrl || I18n.tr("Preparing…", "Placeholder before the sign-in URL is known")
            titleColor: Theme.surfaceTextMedium

            trailing: [
                VgsSpinner {
                    size: 20
                    anchors.verticalCenter: parent.verticalCenter
                }
            ]
        }

        Row {
            width: parent.width
            spacing: Theme.spacingS

            VgsButton {
                text: I18n.tr("Open in browser", "Button that opens the pending sign-in URL")
                iconName: "open_in_new"
                variant: "secondary"
                buttonHeight: 36
                enabled: CloudSyncService.oauthUrl.length > 0
                onClicked: Quickshell.execDetached([Paths.vshellCli, "open", CloudSyncService.oauthUrl])
            }

            VgsButton {
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
                text: I18n.tr("Cancel", "Button that aborts the pending sign-in")
                variant: "secondary"
                buttonHeight: 36
                onClicked: CloudSyncService.cancelOAuth(null)
            }
        }
    }


    CloudSyncCard {
        visible: !CloudSyncService.oauthActive && CloudSyncService.oauthError.length > 0
        iconName: "error"
        title: I18n.tr("Sign-in did not finish", "Card title after a failed OAuth flow")
        description: CloudSyncService.oauthError
    }


    CloudSyncCard {
        visible: CloudSyncService.accounts.length === 0 && !CloudSyncService.oauthActive
        iconName: "cloud_off"
        title: I18n.tr("No accounts yet", "Empty state title on the accounts page")
        description: I18n.tr("Connect Google Drive, Dropbox, OneDrive, an S3 bucket, a WebDAV server, or any of the other services rclone supports. Your credentials are stored in rclone's own config file.", "Empty state body on the accounts page")

        VgsButton {
            text: I18n.tr("Connect an account", "Empty state primary action")
            iconName: "add"
            buttonHeight: 36
            backgroundColor: Theme.primary
            textColor: Theme.primaryText
            enabled: CloudSyncService.daemonRunning
            onClicked: page.parentModal.openDialog("addAccount", {})
        }
    }


    Repeater {
        model: CloudSyncService.accounts

        CloudSyncCard {
            id: accountCard

            required property var modelData

            readonly property string accountName: modelData.name
            readonly property bool expanded: page.expandedAccount === accountCard.accountName
            readonly property var accountFolders: CloudSyncService.foldersForAccount(accountCard.accountName)
            readonly property int accountConflicts: CloudSyncService.conflictsForAccount(accountCard.accountName).length
            readonly property string health: modelData.health || "unknown"
            // Account actions need the engine and must wait while sign-in holds the callback port.
            readonly property bool actionable: CloudSyncService.daemonRunning && !CloudSyncService.oauthActive

            readonly property var quota: modelData.quota || null
            readonly property real usedFraction: {
                if (!quota || !quota.total || quota.total <= 0)
                    return -1;
                return Math.max(0, Math.min(1, (quota.used || 0) / quota.total));
            }


            CloudSyncRow {
                tile: true
                iconName: CloudIcons.providerIcon(accountCard.modelData.type)
                iconColor: Theme.primary
                interactive: true
                title: CloudSyncService.accountName(accountCard.modelData)
                subtitle: CloudSyncService.accountDetail(accountCard.modelData)
                onClicked: page.expandedAccount = accountCard.expanded ? "" : accountCard.accountName

                trailing: [

                    CloudSyncStatusChip {
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: CloudSyncService.healthIcon(accountCard.health)
                        label: CloudSyncService.accountHealthLabel(accountCard.modelData)
                        chipColor: CloudSyncService.healthColor(accountCard.health)
                    },
                    VgsActionButton {
                        iconName: accountCard.expanded ? "expand_less" : "expand_more"
                        tooltipText: accountCard.expanded ? I18n.tr("Hide details", "Tooltip collapsing a cloud account card") : I18n.tr("Show folders and options", "Tooltip expanding a cloud account card")
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: page.expandedAccount = accountCard.expanded ? "" : accountCard.accountName
                    }
                ]
            }

            // Show recovery instructions before the backend diagnostic text.
            Column {
                width: parent.width
                spacing: Theme.spacingXS
                visible: accountCard.health === "error"

                StyledText {
                    width: parent.width
                    text: CloudSyncService.accountHealthHint(accountCard.modelData)
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.error
                }

                StyledText {
                    width: parent.width
                    visible: (accountCard.modelData.error || "").length > 0
                    text: accountCard.modelData.error
                    wrapMode: Text.WordWrap
                    // rclone's own wording is kept for diagnosis but capped:
                    // some backends return a paragraph, and it must not push
                    // the fix out of view.
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }

                VgsButton {
                    visible: accountCard.modelData.oauth === true
                    text: I18n.tr("Reconnect", "Button that signs an existing cloud account in again")
                    iconName: "autorenew"
                    buttonHeight: 32
                    backgroundColor: Theme.primary
                    textColor: Theme.primaryText
                    enabled: accountCard.actionable
                    onClicked: page.parentModal.openDialog("reconnectAccount", {
                        "account": accountCard.accountName
                    })
                }
            }


            Column {
                width: parent.width
                spacing: Theme.spacingXS
                visible: accountCard.usedFraction >= 0

                CloudSyncProgressBar {
                    height: 6
                    fraction: accountCard.usedFraction
                    fillColor: accountCard.usedFraction > 0.9 ? Theme.error : Theme.primary
                }

                Item {
                    width: parent.width
                    height: usedLabel.implicitHeight

                    StyledText {
                        id: usedLabel

                        anchors.left: parent.left
                        anchors.right: freeLabel.left
                        anchors.rightMargin: Theme.spacingS
                        elide: Text.ElideRight
                        text: {
                            if (!accountCard.quota)
                                return "";
                            const used = CloudSyncService.formatBytes(accountCard.quota.used);
                            const total = CloudSyncService.formatBytes(accountCard.quota.total);
                            return used + " " + I18n.tr("of", "Between used and total storage, as in 4 GB of 15 GB") + " " + total + " " + I18n.tr("used", "Suffix after a storage amount");
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        id: freeLabel

                        anchors.right: parent.right
                        visible: accountCard.quota !== null && (accountCard.quota.free || 0) > 0
                        text: accountCard.quota ? CloudSyncService.formatBytes(accountCard.quota.free) + " " + I18n.tr("free", "Suffix after an amount of unused storage") : ""
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: accountCard.usedFraction > 0.9 ? Theme.error : Theme.surfaceTextMedium
                    }
                }
            }


            Row {
                width: parent.width
                spacing: Theme.spacingXS
                visible: !accountCard.expanded

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                        const count = accountCard.accountFolders.length;
                        if (count === 0)
                            return I18n.tr("No folders syncing", "Account summary when the account has no sync pairs");
                        if (count === 1)
                            return I18n.tr("1 folder syncing", "Account summary, single synced folder");
                        return count + " " + I18n.tr("folders syncing", "Account summary, synced folder count");
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: accountCard.accountConflicts > 0
                    text: "· " + (accountCard.accountConflicts === 1 ? I18n.tr("1 conflict", "Account summary, single unresolved conflict") : accountCard.accountConflicts + " " + I18n.tr("conflicts", "Account summary, unresolved conflict count"))
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.warning
                }
            }


            Column {
                width: parent.width
                spacing: Theme.spacingXS
                visible: accountCard.expanded

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.separatorColor
                }

                StyledText {

                    text: I18n.tr("FOLDERS FROM THIS ACCOUNT", "Section header above an account's sync folders")
                    topPadding: Theme.spacingXS
                    bottomPadding: Theme.spacingXXS
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.6
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    width: parent.width
                    visible: accountCard.accountFolders.length === 0
                    text: I18n.tr("Nothing from this account is syncing yet.", "Shown in an expanded account card with no sync folders")
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: accountCard.accountFolders

                    CloudSyncRow {
                        id: folderRow

                        required property var modelData

                        readonly property var status: CloudSyncService.statusFor(modelData.id) || ({})
                        readonly property string state: status.state || "idle"

                        iconName: CloudIcons.modeIcon(modelData.mode)
                        iconColor: Theme.surfaceVariantText
                        interactive: true
                        title: modelData.name || modelData.localPath
                        subtitle: modelData.localPath
                        subtitleElide: Text.ElideMiddle

                        onClicked: page.parentModal.showFolder(modelData.id)

                        trailing: [
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: CloudSyncService.statusLabel(folderRow.state)
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Medium
                                color: CloudSyncService.stateColor(folderRow.state)
                            },
                            VgsIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "chevron_right"
                                size: Theme.iconSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        ]
                    }
                }

                VgsButton {
                    text: I18n.tr("Sync a folder from this account", "Button that starts the add-folder wizard for one account")
                    iconName: "create_new_folder"
                    variant: "secondary"
                    buttonHeight: 32
                    enabled: accountCard.actionable
                    onClicked: page.parentModal.openDialog("addFolder", {
                        "account": accountCard.accountName
                    })
                }
            }


            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: accountCard.expanded

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.separatorColor
                }

                StyledText {
                    width: parent.width
                    topPadding: Theme.spacingXXS
                    text: {
                        const checked = accountCard.modelData.checkedUnix || 0;
                        if (accountCard.health === "checking")
                            return I18n.tr("Checking this account now…", "Status line while an account check is running");
                        if (checked <= 0)
                            return I18n.tr("Not checked yet.", "Status line before an account has been checked");
                        // The relative formatter returns sentence-initial text; embedded dates need separate wording.
                        if (Math.floor(Date.now() / 1000) - checked < 60)
                            return I18n.tr("Checked just now.", "Status line right after an account check");
                        return I18n.tr("Last checked", "Precedes a relative timestamp for an account check") + " " + CloudSyncService.formatRelativeTime(checked).toLowerCase();
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                Flow {
                    width: parent.width
                    spacing: Theme.spacingS

                    VgsButton {
                        text: I18n.tr("Rename", "Button that renames a cloud account for display")
                        iconName: "edit"
                        variant: "secondary"
                        buttonHeight: 32
                        enabled: accountCard.actionable
                        onClicked: page.parentModal.openDialog("renameAccount", {
                            "account": accountCard.accountName
                        })
                    }

                    VgsButton {
                        text: I18n.tr("Check now", "Button that re-verifies a cloud account")
                        iconName: "network_check"
                        variant: "secondary"
                        buttonHeight: 32
                        enabled: accountCard.actionable && accountCard.health !== "checking"
                        onClicked: CloudSyncService.checkRemote(accountCard.accountName, null)
                    }

                    VgsButton {
                        visible: accountCard.modelData.oauth === true
                        text: I18n.tr("Sign in again", "Button that re-runs the browser sign-in for a working account")
                        iconName: "autorenew"
                        variant: "secondary"
                        buttonHeight: 32
                        enabled: accountCard.actionable
                        onClicked: page.parentModal.openDialog("reconnectAccount", {
                            "account": accountCard.accountName
                        })
                    }
                }


                VgsButton {
                    text: I18n.tr("Disconnect account", "Button that removes a cloud account")
                    iconName: "link_off"
                    variant: "secondary"
                    buttonHeight: 32
                    textColor: Theme.error
                    // Wait for pending sign-in before disconnecting so its callback cannot race removal.
                    enabled: accountCard.actionable
                    onClicked: page.parentModal.openDialog("disconnectAccount", {
                        "account": accountCard.accountName
                    })
                }
            }
        }
    }
}
