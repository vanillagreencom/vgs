import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property int refreshSeconds: parseInt(pluginData.refreshSeconds) || 1800

    property bool loading: true
    property int repoCount: 0
    property int aurCount: 0
    property var packages: []
    property string errorText: ""
    property int orphanCount: 0
    property var orphans: []
    property bool showOrphans: false
    readonly property int totalCount: root.repoCount + root.aurCount
    readonly property bool useBackend: SystemUpdateService.sysupdateAvailable

    // ---- Refresh timing / provenance (P1) ----
    // CLI path: local wall-clock of the last successful count, plus the helper's
    // own checkedAt (epoch seconds) when present. Backend path derives both from
    // SystemUpdateService instead.
    property double lastCheckedAtMs: 0
    property int helperCheckedAt: 0
    property string cliSourceLabel: "checkupdates + paru -Qua"

    // Unified "last checked" epoch-ms across both data paths (0 = unknown).
    readonly property double lastCheckedMs: root.useBackend
        ? (SystemUpdateService.lastCheckUnix > 0 ? SystemUpdateService.lastCheckUnix * 1000 : 0)
        : (root.helperCheckedAt > 0 ? root.helperCheckedAt * 1000 : root.lastCheckedAtMs)

    // Human-readable data source for the footer. Empty when unknown (e.g. backend
    // path before backends are populated) so the footer can hide the row rather
    // than advertise a bare, uninformative label.
    readonly property string sourceLabel: root.useBackend
        ? ((SystemUpdateService.backends || []).map(b => b.displayName).filter(Boolean).join(", "))
        : root.cliSourceLabel

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string updateCommand: Paths.vshellCli
    property string pendingLaunchCommand: ""

    Ref {
        service: SystemUpdateService
    }

    onUseBackendChanged: {
        if (root.useBackend) {
            root._syncBackendState();
        } else {
            pollTimer.restart();
        }
    }

    // State color for the pill's *text*. Bar icons stay a single consistent
    // color regardless of whether updates are pending.
    readonly property color accentColor: root.errorText.length > 0 ? Theme.error : (root.totalCount > 0 ? Theme.primary : Theme.surfaceVariantText)

    function pillText() {
        if (root.loading)
            return "…";
        if (root.errorText.length > 0)
            return "!";
        return String(root.totalCount);
    }

    function refresh() {
        if (root.useBackend) {
            root._syncBackendState();
            return;
        }
        if (countProc.running)
            return;
        countProc.running = true;
    }

    // User-initiated refresh from the popout button. For the backend path this
    // forces an actual re-check; the CLI path reuses refresh().
    function manualRefresh() {
        if (root.useBackend) {
            if (SystemUpdateService.isChecking || SystemUpdateService.isUpgrading)
                return;
            SystemUpdateService.checkForUpdates();
            return;
        }
        root.refresh();
    }

    readonly property bool refreshBusy: root.useBackend
        ? (SystemUpdateService.isChecking || SystemUpdateService.isUpgrading)
        : (root.loading || countProc.running)

    function defaultCommandForMode(mode) {
        return "{vshell} update run " + mode;
    }

    function commandForMode(mode) {
        if (mode === "system")
            return String(pluginData.systemUpdateCommand || defaultCommandForMode("system")).trim();
        if (mode === "aur")
            return String(pluginData.aurUpdateCommand || defaultCommandForMode("aur")).trim();
        if (mode === "all")
            return String(pluginData.allUpdateCommand || defaultCommandForMode("all")).trim();
        return "";
    }

    function expandCommand(command) {
        return String(command || "").replace(/\{home\}/g, root.home).replace(/\{vshell\}/g, root.updateCommand);
    }

    function terminalArgv(command) {
        // Keep the configured command out of `sh -c`'s positional command slot.
        // Some terminal-launch paths can lose a trailing argv value, which turns
        // `sh -lc <command>` into the opaque "option requires an argument" error.
        // A fixed script plus an environment argv preserves arbitrary shell syntax
        // while ensuring -c always has an argument and a canonical $0 value.
        return [
            "uwsm", "app", "--",
            "xdg-terminal-exec", "--app-id=TUI.float", "--",
            "env", "VSHELL_UPDATE_COMMAND=" + command,
            "sh", "-lc", "eval \"$VSHELL_UPDATE_COMMAND\"", "vshell-update"
        ];
    }

    function launch(mode, sourcePopout) {
        // The backend owns discovery/state, but button commands are an explicit
        // widget contract and may encode local sequencing (for example repo-only
        // pacman followed by an audited AUR workflow). Never replace them with a
        // backend-generated paru command merely because the backend is online.
        pendingLaunchCommand = commandForMode(mode);
        if (!pendingLaunchCommand.length) {
            ToastService.showWarning("Update command missing", "Set a command in Settings → Bar → Widgets → System Updates.");
            return;
        }
        if (sourcePopout && sourcePopout.closePopout)
            sourcePopout.closePopout();
        launchTimer.restart();
    }

    Timer {
        id: launchTimer
        interval: 75
        repeat: false
        onTriggered: {
            if (!root.pendingLaunchCommand.length)
                return;
            const command = root.expandCommand(root.pendingLaunchCommand);
            root.pendingLaunchCommand = "";
            Quickshell.execDetached(root.terminalArgv(command));
            // Upgrades run detached in a terminal for an unknown duration; poll on a
            // bounded schedule so long upgrades don't leave stale counts, and stop as
            // soon as the count clears (see recheckTimer / onTotalCountChanged).
            root._retryElapsedMs = 0;
            recheckTimer.restart();
        }
    }

    Process {
        id: countProc
        command: [root.updateCommand, "update", "count", "--json"]
        running: false
        stdout: StdioCollector {
            id: countOut
            onStreamFinished: root.parseOutput(countOut.text)
        }
    }

    function parseOutput(txt) {
        if (root.useBackend)
            return;
        root.loading = false;
        try {
            const d = JSON.parse((txt || "").trim());
            // A parsed result (ok or structured error) means a real check happened;
            // prefer the helper's own checkedAt when present so the footer reflects
            // this check even on the error path.
            root.lastCheckedAtMs = Date.now();
            root.helperCheckedAt = parseInt(d.checkedAt) || 0;
            if (d.ok === false) {
                root.errorText = d.error || "update backend unavailable";
                root.repoCount = 0;
                root.aurCount = 0;
                root.packages = [];
                root.orphanCount = 0;
                root.orphans = [];
                return;
            }
            root.errorText = "";
            root.repoCount = d.repo || 0;
            root.aurCount = d.aur || 0;
            root.packages = d.packages || [];
            root.orphanCount = d.orphanCount || 0;
            root.orphans = d.orphans || [];
            if (d.source && d.source.repo && d.source.aur)
                root.cliSourceLabel = d.source.repo + " + " + d.source.aur;
            // Stop the post-upgrade retry on a clean zero. onTotalCountChanged covers
            // the N→0 transition; this also covers the case where the count was
            // already 0 (e.g. after an errored recheck) so the binding doesn't refire.
            if (recheckTimer.running && root.errorText.length === 0 && root.totalCount === 0)
                recheckTimer.stop();
        } catch (e) {
            root.repoCount = 0;
            root.aurCount = 0;
            root.packages = [];
            root.errorText = "parse error";
            root.orphanCount = 0;
            root.orphans = [];
        }
        if (root.orphanCount === 0)
            root.showOrphans = false;
    }

    function _syncBackendState() {
        if (!root.useBackend)
            return;
        root.loading = SystemUpdateService.isChecking;
        root.errorText = SystemUpdateService.hasError ? SystemUpdateService.errorMessage : "";
        const pkgs = (SystemUpdateService.availableUpdates || []).map(p => ({
            "name": p.name || "",
            "src": p.repo === "aur" ? "aur" : "system",
            "old": p.fromVersion || "",
            "new": p.toVersion || ""
        }));
        root.packages = pkgs;
        root.repoCount = pkgs.filter(p => p.src !== "aur").length;
        root.aurCount = pkgs.filter(p => p.src === "aur").length;
        root.orphanCount = 0;
        root.orphans = [];
        root.showOrphans = false;
    }

    Connections {
        target: SystemUpdateService
        function onSysupdateAvailableChanged() { root._syncBackendState(); }
        function onAvailableUpdatesChanged() { root._syncBackendState(); }
        function onIsCheckingChanged() { root._syncBackendState(); }
        function onHasErrorChanged() { root._syncBackendState(); }
        function onErrorMessageChanged() { root._syncBackendState(); }
    }

    function reviewOrphans() {
        const command = String(pluginData.orphanReviewCommand || "").trim();
        if (!command.length)
            return;
        const names = (root.orphans || []).map(o => o.name).join(" ");
        Quickshell.execDetached(["sh", "-lc", command.replace(/\{orphans\}/g, names)]);
    }

    Timer {
        id: pollTimer
        interval: Math.max(300, root.refreshSeconds) * 1000
        repeat: true
        running: !root.useBackend
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // Bounded post-update retry polling (P3): after launching an upgrade we can't
    // observe when the detached terminal finishes, so re-check every 30s for up to
    // 10 minutes. Stops early once totalCount reaches 0 (onTotalCountChanged) and is
    // destroyed with the widget, so there's no unbounded loop. Uses manualRefresh()
    // (a real re-check) rather than refresh(): on the backend path refresh() only
    // re-copies the already-cached service state, so it would never observe the
    // packages the just-finished upgrade cleared — the count would stay stale until
    // the user forced a manual refresh.
    property int _retryElapsedMs: 0
    readonly property int _retryMaxMs: 600000

    Timer {
        id: recheckTimer
        interval: 30000
        repeat: true
        onTriggered: {
            root._retryElapsedMs += interval;
            if (root._retryElapsedMs >= root._retryMaxMs) {
                recheckTimer.stop();
                return;
            }
            root.manualRefresh();
        }
    }

    onTotalCountChanged: {
        // Only a *clean* zero means the upgrade finished. An errored recheck also
        // zeroes the counts (parseOutput sets repo/aur to 0 on failure), so gate on
        // errorText to avoid a transient AUR/DB hiccup killing the retry window.
        if (recheckTimer.running && root.errorText.length === 0 && root.totalCount === 0)
            recheckTimer.stop();
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            VgsIcon {
                name: "upgrade"
                size: root.iconSize
                color: Theme.widgetIconColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.pillText()
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: root.accentColor
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            VgsIcon {
                name: "upgrade"
                size: root.iconSize
                color: Theme.widgetIconColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.pillText()
                font.pixelSize: Theme.fontSizeSmall
                color: root.accentColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutWidth: 380
    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: "System Updates"
            detailsText: root.loading ? "Checking…" : (root.errorText.length > 0 ? root.errorText : (root.totalCount > 0 ? (root.totalCount + " available  (" + root.repoCount + " repo - " + root.aurCount + " aur)") : "Up to date"))
            showCloseButton: true

            Column {
                id: contentCol
                width: parent.width
                spacing: Theme.spacingM

                readonly property int innerWidth: width - leftPadding - rightPadding

                // ---- Toggle link (right-aligned): swaps to the OTHER sheet; the
                //      whole label is clickable and shows that sheet's count. ----
                Item {
                    width: contentCol.innerWidth
                    height: toggleLink.implicitHeight
                    visible: !root.loading && root.orphanCount > 0

                    StyledText {
                        id: toggleLink
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.showOrphans ? (root.totalCount + " packages") : (root.orphanCount + " orphaned")
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        font.underline: linkArea.containsMouse
                        color: Theme.primary

                        MouseArea {
                            id: linkArea
                            anchors.fill: parent
                            anchors.margins: -Theme.spacingXS
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.showOrphans = !root.showOrphans
                        }
                    }
                }

                // ---- Swappable body: cross-fade opacity + animated height so the
                //      toggle grows/shrinks smoothly instead of hard-resizing. ----
                Item {
                    id: bodySwap
                    width: contentCol.innerWidth
                    // Fixed to the taller sheet so toggling never resizes the popout
                    // window — a per-frame Wayland surface resize is what flickers.
                    // Only the internal opacity cross-fade animates.
                    height: Math.max(updatesBody.implicitHeight, orphansBody.implicitHeight)
                    clip: true

                    // ===== UPDATES SHEET =====
                    Column {
                        id: updatesBody
                        width: parent.width
                        spacing: Theme.spacingM
                        opacity: root.showOrphans ? 0 : 1
                        visible: opacity > 0
                        Behavior on opacity {
                            NumberAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing }
                        }

                        StyledText {
                            visible: root.errorText.length > 0
                            width: parent.width
                            text: root.errorText
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        StyledRect {
                            width: parent.width
                            height: Math.min(root.packages.length * 44 + Theme.spacingS * 2, 264)
                            visible: root.errorText.length === 0 && root.packages.length > 0
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            clip: true

                            ListView {
                                id: pkgList
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                model: root.packages
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                delegate: Item {
                                    width: pkgList.width
                                    height: 44

                                    Column {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2

                                        // Line 1: package name (left, bold) + source pill (right)
                                        Item {
                                            width: parent.width
                                            height: Math.max(nameText.implicitHeight, srcPill.height)

                                            StyledText {
                                                id: nameText
                                                anchors.left: parent.left
                                                anchors.right: srcPill.left
                                                anchors.rightMargin: Theme.spacingS
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: modelData.name
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: Font.Bold
                                                color: Theme.surfaceText
                                                elide: Text.ElideRight
                                            }

                                            Rectangle {
                                                id: srcPill
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                radius: height / 2
                                                height: srcPillText.implicitHeight + 3
                                                width: srcPillText.implicitWidth + Theme.spacingS * 2
                                                color: modelData.src === "aur" ? Theme.withAlpha(Theme.secondary, 0.18) : Theme.withAlpha(Theme.primary, 0.18)

                                                StyledText {
                                                    id: srcPillText
                                                    anchors.centerIn: parent
                                                    text: modelData.src === "aur" ? "aur" : "system"
                                                    font.pixelSize: Theme.fontSizeSmall - 1
                                                    font.weight: Font.Medium
                                                    color: modelData.src === "aur" ? Theme.secondary : Theme.primary
                                                }
                                            }
                                        }

                                        // Line 2: current -> new version, smaller
                                        StyledText {
                                            width: parent.width
                                            text: (modelData.old ? modelData.old + "  →  " : "") + modelData.new
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }

                        Column {
                            width: parent.width
                            spacing: Theme.spacingS

                            Row {
                                width: parent.width
                                spacing: Theme.spacingS

                                VgsButton {
                                    width: (parent.width - Theme.spacingS) / 2
                                    text: "Update System"
                                    iconName: "download"
                                    backgroundColor: Theme.surfaceContainerHigh
                                    textColor: Theme.surfaceText
                                    onClicked: root.launch("system", popout)
                                }

                                VgsButton {
                                    width: (parent.width - Theme.spacingS) / 2
                                    text: "Update AUR"
                                    iconName: "deployed_code"
                                    backgroundColor: Theme.surfaceContainerHigh
                                    textColor: Theme.surfaceText
                                    onClicked: root.launch("aur", popout)
                                }
                            }

                            VgsButton {
                                width: parent.width
                                text: "Update All"
                                iconName: "browser_updated"
                                backgroundColor: Theme.primary
                                textColor: Theme.primaryText
                                onClicked: root.launch("all", popout)
                            }
                        }
                    }

                    // ===== ORPHANS SHEET =====
                    Column {
                        id: orphansBody
                        width: parent.width
                        spacing: Theme.spacingS
                        opacity: root.showOrphans ? 1 : 0
                        visible: opacity > 0
                        Behavior on opacity {
                            NumberAnimation { duration: Theme.shortDuration; easing.type: Theme.standardEasing }
                        }

                        StyledText {
                            width: parent.width
                            text: "Orphaned packages"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                        }

                        StyledText {
                            width: parent.width
                            text: "Installed as dependencies, no longer required by anything."
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }

                        StyledRect {
                            visible: root.orphans.length > 0
                            width: parent.width
                            height: Math.min(root.orphans.length * 30 + Theme.spacingS * 2, 240)
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh
                            clip: true

                            ListView {
                                id: orphanList
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                model: root.orphans
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                delegate: Item {
                                    width: orphanList.width
                                    height: 30

                                    StyledText {
                                        id: oName
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.name
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                        width: Math.min(implicitWidth, parent.width * 0.6)
                                    }

                                    StyledText {
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.ver
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideLeft
                                        width: parent.width - oName.width - Theme.spacingS
                                        horizontalAlignment: Text.AlignRight
                                    }
                                }
                            }
                        }

                        StyledText {
                            visible: root.orphans.length === 0
                            width: parent.width
                            text: "No orphaned packages."
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        VgsButton {
                            width: parent.width
                            visible: String(pluginData.orphanReviewCommand || "").trim().length > 0
                            text: "Review orphans"
                            iconName: "manage_search"
                            backgroundColor: Theme.primary
                            textColor: Theme.primaryText
                            onClicked: root.reviewOrphans()
                        }
                    }
                }

                // ---- Footer: data provenance, freshness, manual refresh (P1/P2) ----
                Column {
                    id: footer
                    width: contentCol.innerWidth
                    spacing: Theme.spacingXS
                    visible: !root.showOrphans

                    // Thin divider above the footer.
                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Theme.withAlpha(Theme.outline, 0.4)
                    }

                    // Explanatory copy (P2): the caveat about the checkupdates vs.
                    // paru -S reinstall mismatch. The data source itself is shown by
                    // the "Source:" row below, so this stays a caveat only (no
                    // duplicate "Counts come from …"). Only the CLI/paru path needs it.
                    StyledText {
                        width: parent.width
                        visible: !root.useBackend && root.errorText.length === 0
                        text: "For repo packages use Update System / Update All (or paru -Syu); paru -S <pkg> may still show the old local sync DB."
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }

                    // Last-checked + source labels on the left, refresh on the right.
                    Item {
                        width: parent.width
                        height: Math.max(footerInfo.implicitHeight, refreshBtn.height)

                        Column {
                            id: footerInfo
                            anchors.left: parent.left
                            anchors.right: refreshBtn.left
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            StyledText {
                                width: parent.width
                                text: root.refreshBusy ? "Checking…" : ("Last checked: " + TimeUtils.agoFromMs(root.lastCheckedMs))
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                            }

                            StyledText {
                                width: parent.width
                                visible: root.sourceLabel.length > 0
                                text: "Source: " + root.sourceLabel
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                            }
                        }

                        VgsActionButton {
                            id: refreshBtn
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            buttonSize: 28
                            iconName: "refresh"
                            iconSize: 18
                            iconColor: Theme.surfaceText
                            tooltipText: "Refresh"
                            enabled: !root.refreshBusy
                            opacity: enabled ? 1.0 : 0.5
                            onClicked: root.manualRefresh()

                            RotationAnimator on rotation {
                                from: 0
                                to: 360
                                duration: 1000
                                loops: Animation.Infinite
                                running: root.refreshBusy
                                onRunningChanged: {
                                    if (!running)
                                        refreshBtn.rotation = 0;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
