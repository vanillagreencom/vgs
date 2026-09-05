import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Anchored rows accommodate intrinsic button widths without stretching them.
PluginComponent {
    id: root

    // pillMode: icon | status | speed | count
    property string pillMode: pluginData.pillMode || "status"
    property bool hideWhenIdle: pluginData.hideWhenIdle === true

    Ref {
        service: CloudSyncService
    }

    readonly property string status: CloudSyncService.overallStatus
    readonly property bool syncing: status === "syncing"
    readonly property var transfers: CloudSyncService.transferring
    readonly property var accounts: CloudSyncService.accounts

    _visibilityOverride: true
    _visibilityOverrideValue: CloudSyncService.available && (!root.hideWhenIdle || root.status !== "idle")

    function statusIcon() {
        switch (root.status) {
        case "syncing":
            return "sync";
        case "paused":
            return "cloud_off";
        case "error":
            return "cloud_alert";
        case "conflict":
            return "rule_folder";
        case "offline":
            return "cloud_off";
        case "unconfigured":
            return "cloud_off";
        }
        return "cloud_done";
    }

    readonly property color statusColor: {
        switch (root.status) {
        case "error":
            return Theme.error;
        case "conflict":
            return Theme.warning;
        case "syncing":
            return Theme.primary;
        case "offline":
            return Theme.error;
        case "paused":
            return Theme.surfaceVariantText;
        }
        return Theme.surfaceVariantText;
    }

    function statusShort() {
        switch (root.status) {
        case "syncing":
            return I18n.tr("Syncing", "Short bar label while cloud sync is running");
        case "paused":
            return I18n.tr("Paused", "Short bar label when cloud sync is paused");
        case "error":
            return I18n.tr("Error", "Short bar label when a cloud sync failed");
        case "conflict":
            return I18n.tr("Conflicts", "Short bar label when cloud files need a decision");
        case "offline":
            return I18n.tr("Offline", "Short bar label when the sync engine is not running");
        case "unconfigured":
            return I18n.tr("Set up", "Short bar label when no cloud account is connected yet");
        }
        return I18n.tr("Synced", "Short bar label when everything is up to date");
    }

    function pillText() {
        switch (root.pillMode) {
        case "icon":
            return "";
        case "speed":
            if (root.syncing) {
                const speed = CloudSyncService.formatSpeed(CloudSyncService.aggregateSpeed);
                if (speed.length > 0)
                    return speed;
            }
            return root.statusShort();
        case "count":
            if (root.syncing && root.transfers.length > 0)
                return String(root.transfers.length);
            if (CloudSyncService.conflictCount > 0)
                return String(CloudSyncService.conflictCount);
            return root.statusShort();
        default:
            return root.statusShort();
        }
    }

    function openApp(section) {
        if (section)
            Quickshell.execDetached([Paths.vshellCli, "ipc", "call", "cloudsync", "openWith", section]);
        else
            Quickshell.execDetached([Paths.vshellCli, "ipc", "call", "cloudsync", "open"]);
    }

component PopoutRow: Rectangle {
    id: rowRoot

    property string iconName: ""
    property color iconColor: Theme.surfaceVariantText
    property string title: ""
    property string subtitle: ""
    property color subtitleColor: Theme.surfaceVariantText
    property string trailingText: ""
    property real progress: -1
    property color progressColor: Theme.primary
    property bool filled: true

    width: parent ? parent.width : 0
    height: rowContent.implicitHeight + Theme.spacingS * 2
    radius: Theme.controlRadius
    color: rowRoot.filled ? Theme.surfaceContainer : "transparent"

    Row {
        id: rowContent

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.spacingS
        anchors.rightMargin: Theme.spacingS
        spacing: Theme.spacingS

        readonly property real leadingWidth: rowRoot.iconName === "" ? 0 : 14 + rowContent.spacing
        readonly property real trailingWidth: trailingLabel.visible ? trailingLabel.implicitWidth + rowContent.spacing : 0

        VgsIcon {
            name: rowRoot.iconName
            size: 14
            color: rowRoot.iconColor
            visible: rowRoot.iconName !== ""
            anchors.verticalCenter: parent.verticalCenter
        }

        Column {
            width: Math.max(0, rowContent.width - rowContent.leadingWidth - rowContent.trailingWidth)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXXS

            StyledText {
                width: parent.width
                visible: rowRoot.title.length > 0
                text: rowRoot.title
                elide: Text.ElideMiddle
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }

            StyledRect {
                width: parent.width
                height: 3
                radius: 1.5
                visible: rowRoot.progress >= 0
                color: Theme.surfaceVariantAlpha

                StyledRect {
                    width: parent.width * Math.max(0, Math.min(1, rowRoot.progress))
                    height: parent.height
                    radius: parent.radius
                    color: rowRoot.progressColor
                }
            }

            StyledText {
                width: parent.width
                visible: rowRoot.subtitle.length > 0
                text: rowRoot.subtitle
                elide: Text.ElideRight
                font.pixelSize: Theme.fontSizeSmall - 1
                color: rowRoot.subtitleColor
            }
        }

        StyledText {
            id: trailingLabel
            anchors.verticalCenter: parent.verticalCenter
            visible: rowRoot.trailingText.length > 0
            text: rowRoot.trailingText
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }
}

component SectionHeader: StyledText {
    font.pixelSize: Theme.fontSizeSmall - 1
    font.weight: Font.DemiBold
    font.letterSpacing: 0.6
    color: Theme.surfaceVariantText
}


    Component {
        id: pillIconComponent

        VgsIcon {
            size: root.iconSize
            color: root.status === "error" || root.status === "conflict" ? root.statusColor : Theme.widgetIconColor
            name: root.statusIcon()

            // Theme.shortDuration collapses to 0 when the user disables
            // animations, so the icon simply stops spinning.
            RotationAnimation on rotation {
                running: root.syncing && Theme.shortDuration > 0
                from: 0
                to: 360
                duration: 1600
                loops: Animation.Infinite
                onRunningChanged: {
                    if (!running)
                        rotation = 0;
                }
            }
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            Loader {
                sourceComponent: pillIconComponent
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.pillMode !== "icon" && text.length > 0
                text: root.pillText()
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: root.statusColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            Loader {
                sourceComponent: pillIconComponent
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: root.pillMode !== "icon" && text.length > 0
                text: root.pillText()
                font.pixelSize: Theme.fontSizeSmall
                color: root.statusColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }


    ccWidgetIcon: "cloud_sync"
    ccWidgetPrimaryText: I18n.tr("Cloud Sync", "Control center tile title")
    ccWidgetSecondaryText: {
        if (!CloudSyncService.daemonRunning)
            return I18n.tr("Not running", "Control center tile subtitle when the sync engine is down");
        if (root.syncing) {
            const speed = CloudSyncService.formatSpeed(CloudSyncService.aggregateSpeed);
            return speed.length > 0 ? speed : I18n.tr("Syncing…", "Control center tile subtitle while syncing");
        }
        if (CloudSyncService.paused)
            return I18n.tr("Paused", "Control center tile subtitle when sync is paused");
        if (!CloudSyncService.hasAccounts)
            return I18n.tr("No account", "Control center tile subtitle when nothing is connected");
        return I18n.tr("Up to date", "Control center tile subtitle when everything is synced");
    }
    ccWidgetIsActive: !CloudSyncService.paused && CloudSyncService.hasAccounts
    onCcWidgetToggled: CloudSyncService.togglePaused(null)


    popoutWidth: 400
    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: I18n.tr("Cloud Sync", "Popout title")
            detailsText: {
                if (!CloudSyncService.daemonRunning)
                    return CloudSyncService.daemonError || I18n.tr("Sync engine is not running", "Popout subtitle when rclone is down");
                if (root.syncing) {
                    const eta = CloudSyncService.formatDuration(CloudSyncService.etaSeconds);
                    const speed = CloudSyncService.formatSpeed(CloudSyncService.aggregateSpeed);
                    if (speed.length > 0 && eta.length > 0)
                        return speed + " · " + I18n.tr("about", "Precedes an estimated remaining time") + " " + eta;
                    if (speed.length > 0)
                        return speed;
                    return I18n.tr("Syncing…", "Popout subtitle while syncing");
                }
                if (CloudSyncService.paused)
                    return I18n.tr("Sync is paused", "Popout subtitle when paused");
                if (!CloudSyncService.hasAccounts)
                    return I18n.tr("No cloud account connected yet", "Popout subtitle before setup");
                return I18n.tr("Everything is up to date", "Popout subtitle when idle");
            }
            showCloseButton: true

            // Bar -> Widgets, where a bundled plugin's settings live.
            configurable: true
            onSettingsRequested: PopoutService.openSettingsWithTab("bar_widgets")

            Column {
                width: parent.width
                spacing: Theme.spacingS

                StyledRect {
                    width: parent.width
                    height: summaryColumn.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    border.width: 1
                    border.color: Theme.borderColor

                    Column {
                        id: summaryColumn

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingM
                        spacing: Theme.spacingS

                        Item {
                            width: parent.width
                            height: Math.max(summaryText.implicitHeight, pauseToggle.height, Theme.iconSize)

                            VgsIcon {
                                id: summaryIcon
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                name: root.statusIcon()
                                size: Theme.iconSize
                                color: root.statusColor
                            }

                            Column {
                                id: summaryText
                                anchors.left: summaryIcon.right
                                anchors.right: pauseToggle.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingXXS

                                StyledText {
                                    width: parent.width
                                    text: root.statusShort()
                                    elide: Text.ElideRight
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    width: parent.width
                                    visible: text.length > 0
                                    elide: Text.ElideRight
                                    text: {
                                        if (root.syncing)
                                            return CloudSyncService.globalStats.activeFolder || "";
                                        if (CloudSyncService.attentionStatuses.length > 0)
                                            return CloudSyncService.attentionStatuses[0].lastError || I18n.tr("Needs your attention", "Popout hint when a folder is in an error state");
                                        return "";
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }

                            VgsToggle {
                                id: pauseToggle
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                hideText: true
                                checked: !CloudSyncService.paused
                                enabled: CloudSyncService.daemonRunning
                                onToggled: want => CloudSyncService.setPaused(!want, null)
                            }
                        }

                        // Aggregate progress bar, shown only when rclone knows
                        // the total size (it does not during the scan phase).
                        StyledRect {
                            visible: root.syncing && CloudSyncService.overallProgress >= 0
                            width: parent.width
                            height: 4
                            radius: 2
                            color: Theme.surfaceVariantAlpha

                            StyledRect {
                                width: parent.width * Math.max(0, Math.min(1, CloudSyncService.overallProgress))
                                height: parent.height
                                radius: parent.radius
                                color: Theme.primary

                                Behavior on width {
                                    NumberAnimation {
                                        duration: Theme.shortDuration
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }
                        }

                        Item {
                            visible: root.syncing
                            width: parent.width
                            height: speedRow.implicitHeight

                            Row {
                                id: speedRow
                                anchors.left: parent.left
                                spacing: Theme.spacingM

                                StyledText {
                                    visible: CloudSyncService.uploadSpeed > 0
                                    text: "↑ " + CloudSyncService.formatSpeed(CloudSyncService.uploadSpeed)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceTextMedium
                                }

                                StyledText {
                                    visible: CloudSyncService.downloadSpeed > 0
                                    text: "↓ " + CloudSyncService.formatSpeed(CloudSyncService.downloadSpeed)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceTextMedium
                                }
                            }

                            StyledText {
                                anchors.right: parent.right
                                anchors.verticalCenter: speedRow.verticalCenter
                                visible: CloudSyncService.globalStats.totalBytes > 0
                                text: CloudSyncService.formatBytes(CloudSyncService.globalStats.bytes) + " / " + CloudSyncService.formatBytes(CloudSyncService.globalStats.totalBytes)
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }
                }

                StyledRect {
                    visible: CloudSyncService.available && !CloudSyncService.daemonRunning
                    width: parent.width
                    height: engineColumn.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.errorContainer
                    border.width: 1
                    border.color: Theme.borderColor

                    Column {
                        id: engineColumn

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingM
                        spacing: Theme.spacingS

                        StyledText {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            text: CloudSyncService.daemonError || I18n.tr("The sync engine stopped.", "Popout message when rclone is not running")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                        }

                        VgsButton {
                            text: I18n.tr("Restart sync engine", "Button that restarts the rclone daemon")
                            iconName: "restart_alt"
                            variant: "secondary"
                            buttonHeight: 32
                            onClicked: CloudSyncService.restartDaemon(null)
                        }
                    }
                }

                StyledRect {
                    visible: CloudSyncService.conflictCount > 0
                    width: parent.width
                    height: conflictContent.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.warningContainer
                    border.width: 1
                    border.color: Theme.borderColor

                    Item {
                        id: conflictContent

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingM
                        implicitHeight: Math.max(conflictText.implicitHeight, reviewButton.height)

                        VgsIcon {
                            id: conflictIcon
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            name: "rule_folder"
                            size: Theme.iconSizeSmall
                            color: Theme.warning
                        }

                        StyledText {
                            id: conflictText
                            anchors.left: conflictIcon.right
                            anchors.right: reviewButton.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            wrapMode: Text.WordWrap
                            text: CloudSyncService.conflictCount === 1 ? I18n.tr("1 file changed in both places", "Conflict banner, single file") : CloudSyncService.conflictCount + " " + I18n.tr("files changed in both places", "Conflict banner, multiple files")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                        }

                        VgsButton {
                            id: reviewButton
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: I18n.tr("Review", "Button opening the conflict resolution view")
                            variant: "secondary"
                            buttonHeight: 28
                            horizontalPadding: Theme.spacingM
                            onClicked: {
                                root.openApp("conflicts");
                                if (popout.closePopout)
                                    popout.closePopout();
                            }
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: root.transfers.length > 0

                    SectionHeader {
                        text: I18n.tr("TRANSFERRING", "Popout section header above in-progress files")
                    }

                    Repeater {
                        model: root.transfers.slice(0, 5)

                        PopoutRow {
                            required property var modelData

                            iconName: modelData.direction === "down" ? "download" : "upload"
                            title: modelData.name || ""
                            subtitle: modelData.folderName || ""
                            trailingText: CloudSyncService.formatSpeed(modelData.speed)
                            progress: (modelData.percentage || 0) / 100
                        }
                    }

                    StyledText {
                        visible: root.transfers.length > 5
                        text: "+" + (root.transfers.length - 5) + " " + I18n.tr("more", "Suffix for a truncated transfer list")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: !root.syncing && CloudSyncService.recent.length > 0

                    SectionHeader {
                        text: I18n.tr("RECENTLY SYNCED", "Popout section header above completed files")
                    }

                    Repeater {
                        model: CloudSyncService.recent.slice(0, 5)

                        PopoutRow {
                            required property var modelData

                            filled: false
                            iconName: modelData.error ? "error" : (modelData.direction === "down" ? "download_done" : "cloud_done")
                            iconColor: modelData.error ? Theme.error : Theme.success
                            title: modelData.name || ""
                            trailingText: CloudSyncService.formatBytes(modelData.size)
                        }
                    }
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: root.accounts.length > 0

                    SectionHeader {
                        text: I18n.tr("STORAGE", "Popout section header above cloud account quota bars")
                    }

                    Repeater {
                        model: root.accounts

                        PopoutRow {
                            required property var modelData

                            readonly property real fraction: {
                                if (!modelData.quota || !modelData.quota.total || modelData.quota.total <= 0)
                                    return -1;
                                return Math.max(0, Math.min(1, (modelData.quota.used || 0) / modelData.quota.total));
                            }

                            visible: fraction >= 0
                            filled: false
                            title: modelData.label || modelData.name
                            trailingText: modelData.quota ? CloudSyncService.formatBytes(modelData.quota.used) + " / " + CloudSyncService.formatBytes(modelData.quota.total) : ""
                            progress: fraction
                            progressColor: fraction > 0.9 ? Theme.error : Theme.primary
                        }
                    }
                }

                // VgsButton sizes itself from its content; a Row preserves that width.
                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    VgsButton {
                        text: root.syncing ? I18n.tr("Syncing…", "Disabled button label while a sync is running") : I18n.tr("Sync now", "Button that starts a sync immediately")
                        iconName: "sync"
                        variant: "secondary"
                        buttonHeight: 32
                        enabled: CloudSyncService.daemonRunning && CloudSyncService.hasFolders && !root.syncing
                        onClicked: CloudSyncService.syncNow("", null)
                    }

                    VgsButton {
                        text: CloudSyncService.hasAccounts ? I18n.tr("Open", "Button that opens the Cloud Sync app") : I18n.tr("Set up", "Button that opens the Cloud Sync app for first-time setup")
                        iconName: "open_in_new"
                        backgroundColor: Theme.primary
                        textColor: Theme.primaryText
                        buttonHeight: 32
                        onClicked: {
                            root.openApp("");
                            if (popout.closePopout)
                                popout.closePopout();
                        }
                    }
                }
            }
        }
    }
}
