pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "CloudSyncIcons.js" as CloudIcons

// Accounts is the "what am I connected to" page. Each account is an object with
// its own identity, health, storage and — critically — its own folders: a sync
// pair belongs to exactly one account, which the flat Folders list cannot show.
// The card is where that containment becomes visible, so an account expands
// rather than offering a single row of buttons.
CloudSyncPage {
    id: page

    title: I18n.tr("Accounts", "Cloud Sync accounts page title")
    subtitle: I18n.tr("Cloud services this computer can sync with.", "Cloud Sync accounts page subtitle")

    // One card open at a time: two expanded accounts turn the page into a wall
    // of folder rows with no visible structure. A single account starts open,
    // because there is nothing to choose between.
    //
    // Plain state, not a binding: as a binding it re-evaluated on every state
    // broadcast, so adding a second account collapsed the card the user was
    // reading mid-scroll.
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

    // ---- Sign-in in progress ----
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

    // ---- Last sign-in failed ----
    CloudSyncCard {
        visible: !CloudSyncService.oauthActive && CloudSyncService.oauthError.length > 0
        iconName: "error"
        title: I18n.tr("Sign-in did not finish", "Card title after a failed OAuth flow")
        description: CloudSyncService.oauthError
    }

    // ---- Empty state ----
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

    // ---- Account list ----
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
            // Every account action either talks to rclone or starts a sign-in,
            // and neither is possible while the engine is down or another
            // sign-in already holds the callback port.
            readonly property bool actionable: CloudSyncService.daemonRunning && !CloudSyncService.oauthActive

            readonly property var quota: modelData.quota || null
            readonly property real usedFraction: {
                if (!quota || !quota.total || quota.total <= 0)
                    return -1;
                return Math.max(0, Math.min(1, (quota.used || 0) / quota.total));
            }

            // ---- Identity ----
            CloudSyncRow {
                tile: true
                iconName: CloudIcons.providerIcon(accountCard.modelData.type)
                iconColor: Theme.primary
                interactive: true
                title: CloudSyncService.accountName(accountCard.modelData)
                subtitle: CloudSyncService.accountDetail(accountCard.modelData)
                onClicked: page.expandedAccount = accountCard.expanded ? "" : accountCard.accountName

                trailing: [
                    // Status is shown, not asked for. The previous "Test" button
                    // made the user run a diagnostic to learn something the
                    // service already re-checks on a schedule.
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

            // ---- Health problem ----
            // Our own explanation first, rclone's wording second: "couldn't
            // fetch token: oauth2: cannot fetch token: 400" is not an
            // instruction, but "sign in again, your folders are safe" is.
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

            // ---- Storage ----
            // Free space is what a person actually decides on ("can I sync this
            // folder?"), so it is stated outright rather than left as a
            // subtraction the reader has to perform.
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

            // ---- Collapsed summary ----
            // What collapsing would otherwise hide: how much this account is
            // doing, and whether anything inside it needs a decision.
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

            // ---- Expanded: this account's folders ----
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
                    // Uppercase eyebrow, matching the sidebar's group headers:
                    // at this size it is the only reliable way to read as a
                    // label rather than as another line of body copy.
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
                        // Opens the Folders page, where a folder is actually
                        // managed; the account card only surfaces it.
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

            // ---- Expanded: account actions ----
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
                        // The shared relative formatter is sentence-initial
                        // ("Just now"); mid-sentence it needs its own phrasing.
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

                // The destructive action sits on its own line, away from the
                // rest, so it is never the button next to the one you wanted.
                VgsButton {
                    text: I18n.tr("Disconnect account", "Button that removes a cloud account")
                    iconName: "link_off"
                    variant: "secondary"
                    buttonHeight: 32
                    textColor: Theme.error
                    // Gated like every sibling action: disconnecting an account
                    // whose OAuth callback is still pending leaves the outcome
                    // to backend ordering.
                    enabled: accountCard.actionable
                    onClicked: page.parentModal.openDialog("disconnectAccount", {
                        "account": accountCard.accountName
                    })
                }
            }
        }
    }
}
