import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

// The one system-update checker in the shell. Each bar's SysUpdateWidget is a
// view of this instance, so a poll runs `vshell update count --json` once
// however many screens show the widget, and every screen reports the same
// counts. The upgrade launch lives here for the same reason: the popout that
// asked for it is one of several views of a single machine-wide action.
PluginDaemonComponent {
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
    readonly property int totalCount: root.repoCount + root.aurCount + root.toolsCount
    readonly property bool useBackend: SystemUpdateService.sysupdateAvailable

    property string cliSourceLabel: "checkupdates + paru -Qua"

    readonly property string sourceLabel: root.useBackend
        ? ((SystemUpdateService.backends || []).map(b => b.displayName).filter(Boolean).join(", "))
        : root.cliSourceLabel

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string updateCommand: Paths.vshellCli
    property string pendingLaunchCommand: ""

    Ref {
        service: SystemUpdateService
    }

    // Imperative Timer control is out: pollTimer.restart() would overwrite the
    // `running` binding below with a plain true, and the poll would then keep
    // spawning a count per interval with no widget watching. The binding turns
    // the poll back on by itself when the backend goes away, and
    // triggeredOnStart counts at once.
    onUseBackendChanged: {
        if (root.useBackend)
            root._syncBackendState();
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

    // User-initiated refresh from a popout button. For the backend path this
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

    function launch(mode) {
        const command = commandForMode(mode);
        if (!command.length) {
            ToastService.showWarning("Update command missing", "Set a command in Settings → Bar → Widgets → System Updates.");
            return;
        }
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
        // Poll only while a widget watches, so the first watching widget counts
        // at once and a shell with the widget off every bar spawns nothing.
        running: !root.useBackend && root.watched
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
            // Nothing reads the count while no widget watches; the poll's
            // triggeredOnStart re-checks as soon as one does.
            if (root.watched)
                root.manualRefresh();
        }
    }

    onTotalCountChanged: {
        // An errored check can clear counts without establishing that work finished.
        if (recheckTimer.running && root.errorText.length === 0 && root.totalCount === 0)
            recheckTimer.stop();
    }
}
