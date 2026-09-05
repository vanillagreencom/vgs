import QtQuick
import QtQuick.Controls
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
    property int toolsCount: 0
    // mise is installed: the backend advertises a tools backend, or the CLI
    // count named a tools source.
    property bool toolsAvailable: false
    // The mise probe failed while the repo count succeeded; shown instead of a
    // false "0 tools".
    property string toolsError: ""
    property var packages: []
    property string errorText: ""
    property int orphanCount: 0
    property var orphans: []
    property bool showOrphans: false
    readonly property int totalCount: root.repoCount + root.aurCount + root.toolsCount
    readonly property bool useBackend: SystemUpdateService.sysupdateAvailable

    property string cliSourceLabel: "checkupdates + paru -Qua"

    // Hide the source row until a data source is known. It is the only thing
    // left in that footer: the refresh control moved to the shared header slot
    // and the "last checked" stamp beside it went with it.
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

    // Use state color for pill text while retaining the bar icon color.
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

    // Nothing to install anywhere, and every source answered. A failed tools
    // check is an unknown rather than a clear result, so it is not allClear:
    // the upgrade buttons stay in that case.
    readonly property bool allClear: !root.loading
        && root.errorText.length === 0
        && root.toolsError.length === 0
        && root.totalCount === 0

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
        if (mode === "tools")
            return String(pluginData.toolsUpdateCommand || defaultCommandForMode("tools")).trim();
        if (mode === "all")
            return String(pluginData.allUpdateCommand || defaultCommandForMode("all")).trim();
        return "";
    }

    function expandCommand(command) {
        return String(command || "").replace(/\{home\}/g, root.home).replace(/\{vshell\}/g, root.updateCommand);
    }

    function terminalArgv(command) {
        // Pass the configured command through an environment argument so sh -c
        // always has a script and $0. vshell terminal owns terminal selection.
        return [
            root.updateCommand, "terminal", "exec", "--tui", "--",
            "env", "VSHELL_UPDATE_COMMAND=" + command,
            "sh", "-lc", "eval \"$VSHELL_UPDATE_COMMAND\"", "vshell-update"
        ];
    }

    function launch(mode, sourcePopout) {
        const command = commandForMode(mode);
        if (!command.length) {
            ToastService.showWarning("Update command missing", "Set a command in Settings → Bar → Widgets → System Updates.");
            return;
        }
        if (sourcePopout && sourcePopout.closePopout)
            sourcePopout.closePopout();
        // A button on its default runs through the backend, which supervises
        // the terminal and re-counts when it exits. A custom command is an
        // explicit widget contract that may encode local sequencing (repo-only
        // pacman followed by an audited AUR workflow); it keeps the detached
        // launch and the bounded re-check instead.
        if (root.useBackend && command === defaultCommandForMode(mode)) {
            SystemUpdateService.upgrade(mode, response => {
                if (response && response.error)
                    ToastService.showError("Update failed to start", String(response.error));
            });
            return;
        }
        pendingLaunchCommand = command;
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
            // A detached upgrade has no observed exit. Re-check on a bounded schedule.
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
            if (d.ok === false) {
                root.errorText = d.error || "update backend unavailable";
                root.repoCount = 0;
                root.aurCount = 0;
                root.toolsCount = 0;
                root.packages = [];
                root.orphanCount = 0;
                root.orphans = [];
                return;
            }
            root.errorText = "";
            root.repoCount = d.repo || 0;
            root.aurCount = d.aur || 0;
            root.toolsCount = d.tools || 0;
            root.toolsAvailable = !!(d.source && d.source.tools);
            root.toolsError = String(d.toolsError || "");
            root.packages = d.packages || [];
            root.orphanCount = d.orphanCount || 0;
            root.orphans = d.orphans || [];
            if (d.source && d.source.repo && d.source.aur)
                root.cliSourceLabel = d.source.repo + " + " + d.source.aur;
            // Stop on a clean zero even if the count was already zero and its change
            // signal does not fire.
            if (recheckTimer.running && root.errorText.length === 0 && root.totalCount === 0)
                recheckTimer.stop();
        } catch (e) {
            root.repoCount = 0;
            root.aurCount = 0;
            root.toolsCount = 0;
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
            "src": p.repo === "aur" ? "aur" : (p.repo === "tools" ? "tools" : "system"),
            "old": p.fromVersion || "",
            "new": p.toVersion || ""
        }));
        root.packages = pkgs;
        root.repoCount = pkgs.filter(p => p.src === "system").length;
        root.aurCount = pkgs.filter(p => p.src === "aur").length;
        root.toolsCount = pkgs.filter(p => p.src === "tools").length;
        root.toolsAvailable = SystemUpdateService.hasBackend("mise");
        root.toolsError = "";
        root.orphanCount = 0;
        root.orphans = [];
        root.showOrphans = false;
    }

    Connections {
        target: SystemUpdateService
        function onSysupdateAvailableChanged() { root._syncBackendState(); }
        function onAvailableUpdatesChanged() { root._syncBackendState(); }
        function onBackendsChanged() { root._syncBackendState(); }
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

    // Detached upgrades have no observed exit. Bound retries with _retryMaxMs.
    // Use manualRefresh because refresh can copy cached backend state.
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
        // An errored check can clear counts without establishing that work finished.
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
            detailsText: root.loading ? "Checking…" : (root.errorText.length > 0 ? root.errorText : (root.totalCount > 0 ? (root.totalCount + " available  (" + root.repoCount + " repo - " + root.aurCount + " aur" + (root.toolsAvailable ? " - " + (root.toolsError ? "tools ?" : root.toolsCount + " tools") : "") + ")") : (root.toolsError ? "Up to date (tools check failed)" : "")))
            showCloseButton: true

            // Bar -> Widgets, where a bundled plugin's settings live.
            configurable: true
            onSettingsRequested: PopoutService.openSettingsWithTab("bar_widgets")

            // The shared header slot. This control used to sit in the footer
            // beside a "Last checked" line; it is in the header now, where
            // every other bar flyout keeps it.
            refreshable: true
            refreshBusy: root.refreshBusy
            onRefreshRequested: root.manualRefresh()

            Column {
                id: contentCol
                width: parent.width
                spacing: Theme.spacingM

                readonly property int innerWidth: width - leftPadding - rightPadding

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

                Item {
                    id: bodySwap
                    width: contentCol.innerWidth
                    // Fixed to the taller sheet so toggling never resizes the popout
                    // window — a per-frame Wayland surface resize is what flickers.
                    // Only the internal opacity cross-fade animates.
                    height: Math.max(updatesBody.implicitHeight, orphansBody.implicitHeight)
                    clip: true

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
                            visible: root.errorText.length === 0 && root.toolsError.length > 0
                            width: parent.width
                            text: "Dev tools check failed: " + root.toolsError
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.error
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
                                anchors.rightMargin: 2
                                model: root.packages
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                ScrollBar.vertical: VgsScrollbar {
                                }

                                delegate: Item {
                                    width: pkgList.width - Theme.spacingS + 2
                                    height: 44

                                    Rectangle {
                                        id: srcPill
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        radius: height / 2
                                        height: srcPillText.implicitHeight + 3
                                        width: srcPillText.implicitWidth + Theme.spacingS * 2
                                        color: Theme.withAlpha(srcPillText.color, 0.18)

                                        StyledText {
                                            id: srcPillText
                                            anchors.centerIn: parent
                                            text: modelData.src === "aur" ? "aur" : (modelData.src === "tools" ? "tools" : "system")
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            font.weight: Font.Medium
                                            color: modelData.src === "aur" ? Theme.secondary : (modelData.src === "tools" ? Theme.tertiary : Theme.primary)
                                        }
                                    }

                                    Column {
                                        anchors.left: parent.left
                                        anchors.right: srcPill.left
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 2

                                        StyledText {
                                            width: parent.width
                                            text: modelData.name
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Bold
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                        }

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

                        UpToDateState {
                            width: parent.width
                            visible: root.allClear
                            toolsAvailable: root.toolsAvailable
                        }

                        UpdateActions {
                            width: parent.width
                            visible: !root.allClear
                            host: root
                            onLaunchRequested: mode => root.launch(mode, popout)
                        }
                    }

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
                                anchors.rightMargin: 2
                                model: root.orphans
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                ScrollBar.vertical: VgsScrollbar {
                                }

                                delegate: Item {
                                    width: orphanList.width - Theme.spacingS + 2
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

                Column {
                    id: footer
                    width: contentCol.innerWidth
                    spacing: Theme.spacingXS
                    visible: !root.showOrphans

                    // The CLI count can differ from what paru reinstalls. Show that caveat
                    // only on the CLI path.
                    StyledText {
                        width: parent.width
                        visible: !root.useBackend && root.errorText.length === 0 && !root.allClear
                        text: "For repo packages use Update System / Update All (or paru -Syu); paru -S <pkg> may still show the old local sync DB."
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }

                    // Which tool answered, and nothing else.
                    StyledText {
                        width: parent.width
                        visible: root.sourceLabel.length > 0
                        text: "Source: " + root.sourceLabel
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }
}
