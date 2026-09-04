import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "CloudSyncIcons.js" as CloudIcons

CloudSyncPage {
    id: page

    title: I18n.tr("Folders", "Cloud Sync folders page title")
    subtitle: I18n.tr("Folders on this computer that are kept in step with the cloud.", "Cloud Sync folders page subtitle")

    // Offer account filtering when the folder list spans several accounts.
    property string accountFilter: ""

    readonly property bool canFilter: CloudSyncService.accounts.length > 1

    readonly property var filterChips: {
        const chips = [
            {
                "name": "",
                "label": I18n.tr("All", "Folder filter chip showing every account's folders"),
                "count": CloudSyncService.folders.length
            }
        ];
        for (const account of CloudSyncService.accounts) {
            chips.push({
                "name": account.name,
                "label": CloudSyncService.accountName(account),
                "count": CloudSyncService.foldersForAccount(account.name).length
            });
        }
        return chips;
    }

    readonly property var visibleFolders: page.accountFilter.length === 0 ? CloudSyncService.folders : CloudSyncService.foldersForAccount(page.accountFilter)

    // VgsFilterChips writes currentIndex on click. Reconcile account changes explicitly because that write replaces a binding.
    function syncFilter() {
        if (page.accountFilter.length > 0 && CloudSyncService.accountByName(page.accountFilter) === null)
            page.accountFilter = "";
        for (var i = 0; i < page.filterChips.length; i++) {
            if (page.filterChips[i].name === page.accountFilter) {
                filterChipRow.currentIndex = i;
                return;
            }
        }
        filterChipRow.currentIndex = 0;
    }

    Connections {
        target: CloudSyncService

        // Clear a removed account filter so folders do not remain hidden behind a vanished chip.
        function onAccountsChanged() {
            page.syncFilter();
        }
    }

    headerAction: [
        VgsButton {
            text: I18n.tr("Add folder", "Button that starts the add-folder wizard")
            iconName: "create_new_folder"
            buttonHeight: 36
            backgroundColor: Theme.primary
            textColor: Theme.primaryText
            enabled: CloudSyncService.daemonRunning && CloudSyncService.hasAccounts
            onClicked: page.parentModal.openDialog("addFolder", {})
        }
    ]


    VgsFilterChips {
        id: filterChipRow

        visible: page.canFilter && CloudSyncService.folders.length > 0
        width: parent.width
        model: page.filterChips
        onSelectionChanged: index => {
            const chip = page.filterChips[index];
            page.accountFilter = chip ? chip.name : "";
        }
    }


    CloudSyncCard {
        visible: CloudSyncService.hasFolders && page.visibleFolders.length === 0
        iconName: "filter_alt_off"
        title: I18n.tr("Nothing from this account", "Empty state title when an account filter matches no folders")
        description: I18n.tr("This account is connected but nothing syncs through it yet.", "Empty state body when an account filter matches no folders")

        VgsButton {
            text: I18n.tr("Sync a folder from this account", "Button that starts the add-folder wizard for one account")
            iconName: "create_new_folder"
            buttonHeight: 36
            backgroundColor: Theme.primary
            textColor: Theme.primaryText
            enabled: CloudSyncService.daemonRunning
            onClicked: page.parentModal.openDialog("addFolder", {
                "account": page.accountFilter
            })
        }
    }


    CloudSyncCard {
        visible: !CloudSyncService.hasAccounts
        iconName: "account_circle"
        title: I18n.tr("Connect an account first", "Empty state title when no cloud account exists")
        description: I18n.tr("Sync folders need somewhere to sync to. Add a cloud account, then come back here to choose what to sync.", "Empty state body when no cloud account exists")
    }


    CloudSyncCard {
        visible: CloudSyncService.hasAccounts && CloudSyncService.folders.length === 0
        iconName: "create_new_folder"
        title: I18n.tr("No folders yet", "Empty state title on the folders page")
        description: I18n.tr("Pick a folder on this computer and a folder in the cloud, then choose how they should stay in step.", "Empty state body on the folders page")

        VgsButton {
            text: I18n.tr("Add your first folder", "Empty state primary action on the folders page")
            iconName: "create_new_folder"
            buttonHeight: 36
            backgroundColor: Theme.primary
            textColor: Theme.primaryText
            onClicked: page.parentModal.openDialog("addFolder", {})
        }
    }


    CloudSyncCard {
        visible: CloudSyncService.paused && CloudSyncService.folders.length > 0
        iconName: "pause_circle"
        title: I18n.tr("Sync is paused", "Card title when global pause is on")
        description: I18n.tr("Nothing will sync until you resume, including scheduled and real-time folders.", "Card body when global pause is on")

        VgsButton {
            text: I18n.tr("Resume sync", "Button that lifts the global pause")
            iconName: "play_arrow"
            buttonHeight: 36
            backgroundColor: Theme.primary
            textColor: Theme.primaryText
            onClicked: CloudSyncService.setPaused(false, null)
        }
    }


    Repeater {
        model: page.visibleFolders

        CloudSyncCard {
            id: folderCard

            required property var modelData

            // parentModal arrives after component completion. Handle it here so cross-page navigation can scroll and highlight the target.
            highlighted: page.parentModal ? page.parentModal.highlightFolderId === modelData.id : false

            onHighlightedChanged: {
                if (folderCard.highlighted)
                    Qt.callLater(() => page.scrollToItem(folderCard));
            }

            readonly property var status: CloudSyncService.statusFor(modelData.id) || ({})
            readonly property string state: status.state || "idle"
            readonly property bool isSyncing: state === "syncing"
            readonly property bool isStream: modelData.mode === "stream"
            readonly property bool needsResync: state === "needsResync"
            readonly property var liveTransfers: CloudSyncService.transfersForFolder(modelData.id)

            readonly property color stateColor: CloudSyncService.stateColor(folderCard.state)


            CloudSyncRow {
                tile: true
                iconName: CloudIcons.modeIcon(folderCard.modelData.mode)
                iconColor: Theme.primary
                title: folderCard.modelData.name || folderCard.modelData.localPath
                subtitle: folderCard.modelData.localPath + "  ⇄  " + CloudSyncService.accountLabelFor(folderCard.modelData.remote) + "/" + (folderCard.modelData.remotePath || "")
                subtitleElide: Text.ElideMiddle

                trailing: [
                    CloudSyncStatusChip {
                        anchors.verticalCenter: parent.verticalCenter
                        iconName: CloudIcons.stateIcon(folderCard.state)
                        label: CloudSyncService.statusLabel(folderCard.state)
                        chipColor: folderCard.stateColor
                    }
                ]


                body: [
                    Column {
                        width: parent.width
                        spacing: Theme.spacingXXS
                        visible: folderCard.isSyncing

                        CloudSyncProgressBar {
                            fraction: {
                                const total = folderCard.status.totalBytes || 0;
                                if (total <= 0)
                                    return -1;
                                return (folderCard.status.bytes || 0) / total;
                            }
                        }

                        Item {
                            width: parent.width
                            height: progressLabel.implicitHeight

                            StyledText {
                                id: progressLabel
                                anchors.left: parent.left
                                anchors.right: speedLabel.left
                                anchors.rightMargin: Theme.spacingS
                                elide: Text.ElideMiddle
                                text: folderCard.liveTransfers.length > 0 ? folderCard.liveTransfers[0].name : I18n.tr("Checking for changes…", "Shown while rclone is scanning before transferring")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceTextMedium
                            }

                            StyledText {
                                id: speedLabel
                                anchors.right: parent.right
                                text: CloudSyncService.formatSpeed(folderCard.status.speed)
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }
                ]
            }


            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall
                color: folderCard.state === "error" ? Theme.error : Theme.surfaceVariantText
                text: {
                    if (folderCard.state === "error" && folderCard.status.lastError)
                        return folderCard.status.lastError;
                    if (folderCard.needsResync)
                        return I18n.tr("Two-way sync needs a starting point. Choose which side wins the first time they are compared.", "Explanation shown on a folder awaiting its bisync baseline");
                    if (folderCard.isStream)
                        return folderCard.status.mounted ? I18n.tr("Files appear in", "Precedes a mount point path") + " " + folderCard.modelData.localPath : I18n.tr("Not connected. Files are not available offline.", "Shown when an on-demand folder is unmounted");

                    const parts = [];
                    parts.push(CloudSyncService.modeLabel(folderCard.modelData.mode));

                    if (!folderCard.status.lastSuccessUnix || folderCard.status.lastSuccessUnix <= 0)
                        parts.push(I18n.tr("Never synced", "Shown for a folder that has not completed a sync yet"));
                    else
                        parts.push(I18n.tr("Last synced", "Precedes a relative timestamp") + " " + CloudSyncService.formatRelativeTime(folderCard.status.lastSuccessUnix).toLowerCase());
                    if (folderCard.modelData.realTime)
                        parts.push(folderCard.status.watching ? I18n.tr("Real-time on", "Shown when the inotify watcher is active for a folder") : I18n.tr("Real-time unavailable", "Shown when the inotify watcher could not be armed"));
                    else if (folderCard.modelData.intervalSeconds > 0)
                        parts.push(I18n.tr("Every", "Precedes a sync interval") + " " + CloudSyncService.formatDuration(folderCard.modelData.intervalSeconds));
                    return parts.join(" · ");
                }
            }

            // An unreachable account can leave a folder idle without a sync attempt. Show the account error instead of implying success.
            StyledText {
                readonly property var folderAccount: CloudSyncService.accountByName(folderCard.modelData.remote)

                visible: folderAccount !== null && folderAccount.health === "error"
                width: parent.width
                wrapMode: Text.WordWrap
                text: I18n.tr("This folder's account needs attention, so it cannot sync right now.", "Shown on a folder whose cloud account is unreachable")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.warning
            }

            StyledText {
                visible: (folderCard.status.watchDegraded || "").length > 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: folderCard.status.watchDegraded || ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.warning
            }

            // Move icon actions to another line when the row cannot fit them beside the text buttons.
            Item {
                id: actions

                readonly property bool sideBySide: actionsRow.width + iconsRow.width + Theme.spacingS <= width

                width: parent.width
                height: actions.sideBySide ? Math.max(actionsRow.implicitHeight, iconsRow.implicitHeight) : actionsRow.implicitHeight + iconsRow.implicitHeight + Theme.spacingS

                Row {
                    id: actionsRow
                    anchors.left: parent.left
                    anchors.top: parent.top
                    spacing: Theme.spacingS

                    VgsButton {
                        visible: folderCard.needsResync
                        text: I18n.tr("Set up two-way sync", "Button that opens the bisync baseline dialog")
                        iconName: "rule_settings"
                        buttonHeight: 32
                        backgroundColor: Theme.primary
                        textColor: Theme.primaryText
                        onClicked: page.parentModal.openDialog("resync", {
                            "folderId": folderCard.modelData.id
                        })
                    }

                    VgsButton {
                        visible: folderCard.isStream
                        text: folderCard.status.mounted ? I18n.tr("Disconnect", "Button that unmounts an on-demand folder") : I18n.tr("Connect", "Button that mounts an on-demand folder")
                        iconName: folderCard.status.mounted ? "link_off" : "link"
                        variant: "secondary"
                        buttonHeight: 32
                        enabled: CloudSyncService.daemonRunning && CloudSyncService.canMount
                        onClicked: {
                            if (folderCard.status.mounted)
                                CloudSyncService.unmount(folderCard.modelData.id, null);
                            else
                                CloudSyncService.mount(folderCard.modelData.id, null);
                        }
                    }

                    VgsButton {
                        visible: !folderCard.isStream && !folderCard.needsResync
                        text: folderCard.isSyncing ? I18n.tr("Stop", "Button that cancels a running sync") : I18n.tr("Sync now", "Button that starts a sync immediately")
                        iconName: folderCard.isSyncing ? "stop" : "sync"
                        variant: "secondary"
                        buttonHeight: 32
                        enabled: CloudSyncService.daemonRunning
                        onClicked: {
                            if (folderCard.isSyncing)
                                CloudSyncService.cancelJob(folderCard.modelData.id, null);
                            else
                                CloudSyncService.syncNow(folderCard.modelData.id, null);
                        }
                    }

                    VgsButton {
                        visible: CloudSyncService.blockedByDeleteGuard(folderCard.status)
                        text: I18n.tr("Sync anyway", "Button that overrides the delete guard after a stopped sync")
                        iconName: "warning"
                        variant: "secondary"
                        buttonHeight: 32
                        enabled: CloudSyncService.daemonRunning && !folderCard.isSyncing
                        onClicked: CloudSyncService.syncAnyway(folderCard.modelData.id, null)
                    }

                    VgsButton {
                        visible: !folderCard.isStream
                        text: folderCard.modelData.paused ? I18n.tr("Resume", "Button that resumes a paused folder") : I18n.tr("Pause", "Button that pauses a folder")
                        iconName: folderCard.modelData.paused ? "play_arrow" : "pause"
                        variant: "secondary"
                        buttonHeight: 32
                        onClicked: CloudSyncService.setFolderPaused(folderCard.modelData.id, !folderCard.modelData.paused, null)
                    }
                }

                Row {
                    id: iconsRow

                    // Position controls explicitly because toggling anchors can leave part of the wide layout applied.
                    x: actions.sideBySide ? Math.max(0, actions.width - width) : 0
                    y: actions.sideBySide ? Math.round((actionsRow.height - height) / 2) : actionsRow.height + Theme.spacingS
                    spacing: Theme.spacingXS

                    VgsActionButton {
                        iconName: "folder_open"
                        tooltipText: I18n.tr("Open folder", "Tooltip for opening the local folder in a file manager")
                        onClicked: Quickshell.execDetached([Paths.vshellCli, "open", folderCard.modelData.localPath])
                    }

                    VgsActionButton {
                        iconName: "tune"
                        tooltipText: I18n.tr("Folder options", "Tooltip for editing a folder's sync options")
                        onClicked: page.parentModal.openDialog("folderOptions", {
                            "folderId": folderCard.modelData.id
                        })
                    }
                }
            }
        }
    }
}
