pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("CompositorService")

    property bool isHyprland: false
    property bool isNiri: false
    readonly property bool isMango: false
    readonly property bool isSway: false
    readonly property bool isScroll: false
    readonly property bool isMiracle: false
    readonly property bool isLabwc: false
    property string compositor: "unknown"
    property bool compositorDetected: false
    readonly property bool useHyprlandFocusGrab: isHyprland && Quickshell.env("VSHELL_HYPRLAND_EXCLUSIVE_FOCUS") !== "1"
    readonly property string hyprlandSignature: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
    readonly property string niriSocket: Quickshell.env("NIRI_SOCKET")

    property var randrScales: ({})
    property bool randrReady: true
    property var sortedToplevels: []
    property var hyprlandVisibleSpecialWorkspaces: ({})
    signal randrDataReady
    signal toplevelsChanged

    // The focused Hyprland workspace, or an empty string when unknown.
    // Read activeToplevel because monitor snapshots can be stale during focus changes.
    // This service owns shared compositor focus; consumers must not create competing subscriptions.
    readonly property string activeWorkspaceName: isHyprland ? (Hyprland.activeToplevel?.workspace?.name ?? "") : ""

    // Focus source state: pending until detection returns, hyprland or niri on success, unknown on failure.
    // Separate pending from unknown so consumers can wait for detection.
    readonly property string focusSource: !compositorDetected
        ? "pending"
        : (isNiri ? "niri" : (isHyprland ? "hyprland" : "unknown"))

    // Niri readiness requires a connected event stream and a received window snapshot.
    // Hyprland and unknown sources use ToplevelManager, which exposes no initial-snapshot completion signal.
    // Treat these sources as ready after detection; an empty initial list can resolve to Ctrl+V before windows arrive.
    // A connected Niri socket does not prove the peer is responding; PasteService bounds that wait.
    readonly property bool focusReady: focusSource === "niri"
        ? (NiriService.eventStreamUp && NiriService.windowsSnapshotReceived)
        : focusSource !== "pending"

    // The focused app id, or an empty string when unavailable. Check focusReady before using it.
    // Niri maintains at most one is_focused window. Other sources use the active toplevel.
    // If Niri detection fails, this fallback can select Ctrl+V for a terminal.
    readonly property string focusedAppId: focusSource === "niri"
        ? (focusReady ? ((NiriService.windows ?? []).find(window => window.is_focused)?.app_id ?? "") : "")
        : (focusReady ? (ToplevelManager.activeToplevel?.appId ?? "") : "")

    // Retain the last focused app while shell surfaces temporarily take keyboard focus.
    // Only return a remembered window while it remains in its compositor live-window list and focus is ready.
    property var _lastFocusedToplevel: null
    property var _lastFocusedNiriWindowId: null
    readonly property string lastFocusedAppId: focusSource === "niri"
        ? (focusReady ? ((NiriService.windows ?? []).find(window => window.id === _lastFocusedNiriWindowId)?.app_id ?? "") : "")
        : (focusReady ? (_lastFocusedToplevel && (ToplevelManager.toplevels?.values ?? []).includes(_lastFocusedToplevel) ? (_lastFocusedToplevel.appId ?? "") : "") : "")

    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() {
            if (ToplevelManager.activeToplevel)
                root._lastFocusedToplevel = ToplevelManager.activeToplevel;
        }
    }

    // Do not overwrite remembered Niri focus when a shell surface leaves no application focused.
    function rememberNiriFocus() {
        const focused = (NiriService.windows ?? []).find(window => window.is_focused);
        if (focused)
            root._lastFocusedNiriWindowId = focused.id;
    }

    // Seed focus already present at construction because no change signal reports it.
    // Seed again after asynchronous compositor detection makes Niri state available.
    function seedRememberedFocus() {
        if (ToplevelManager.activeToplevel)
            root._lastFocusedToplevel = ToplevelManager.activeToplevel;
        if (isNiri)
            rememberNiriFocus();
    }

    Component.onCompleted: {
        detectCompositor();
        refreshToplevels();
        seedRememberedFocus();
        randrDataReady();
    }

    Connections {
        target: ToplevelManager.toplevels
        // Share the coalescing timer with the Hyprland fan-out. Opening a window reaches both
        // producers, and a direct call here would rebuild every consumer a second time.
        function onValuesChanged() { toplevelViewTimer.restart(); }
    }

    Connections {
        target: NiriService
        function onWindowsChanged() {
            if (root.isNiri) {
                root.rememberNiriFocus();
                root.refreshToplevels();
            }
        }
        function onAllWorkspacesChanged() {
            if (root.isNiri)
                root.refreshToplevels();
        }
    }

    // Hyprland announces one action under a v1 and a v2 name: activewindow/activewindowv2,
    // workspace/workspacev2, focusedmon/focusedmonv2, movewindow/movewindowv2. Neither list
    // below carries both names of a pair, because matching the pair does the work twice.

    // Events after which a consumer reads a HyprlandMonitor field that Quickshell refetches
    // only on request. Dock scratchpad reveal reads monitor.lastIpcObject.specialWorkspace,
    // which activespecial invalidates; hotplug and monitor focus change which monitor that
    // read lands on.
    readonly property var _hyprMonitorRefreshEvents: ["monitoradded", "monitorremoved", "focusedmonv2", "activespecial"]

    // Events after which the toplevel view must be rebuilt. Bar, dock and focused-app widgets
    // rebuild imperatively from toplevelsChanged, and filterCurrentWorkspace resolves the
    // active workspace per screen from Hyprland.monitors, so a hotplug that migrates
    // workspaces stales the surviving bar's list without touching ToplevelManager.
    readonly property var _hyprToplevelViewEvents: ["openwindow", "closewindow", "movewindowv2", "workspacev2", "focusedmonv2", "activewindowv2", "changefloatingmode", "fullscreen", "moveintogroup", "moveoutofgroup", "activespecial", "monitoradded", "monitorremoved"]

    Connections {
        target: root.isHyprland ? Hyprland : null
        enabled: root.isHyprland
        function onRawEvent(event) {
            if (root._hyprMonitorRefreshEvents.includes(event.name))
                hyprMonitorRefreshTimer.restart();
            if (root._hyprToplevelViewEvents.includes(event.name))
                toplevelViewTimer.restart();
        }
    }

    // One action still emits several matched events: a workspace switch emits workspacev2 and
    // activewindowv2. Collapse them into one refresh per event-loop turn.
    Timer {
        id: hyprMonitorRefreshTimer
        interval: 0
        repeat: false
        onTriggered: root.refreshMonitors()
    }

    // The Hyprland fan-out and ToplevelManager share this timer; ToplevelManager reaches it
    // on every compositor. The two NiriService handlers above are not routed through it and
    // rebuild directly, so the one-rebuild-per-action property holds on Hyprland only.
    Timer {
        id: toplevelViewTimer
        interval: 0
        repeat: false
        onTriggered: root.refreshToplevels()
    }

    function refreshToplevels() {
        const values = Array.from(ToplevelManager.toplevels?.values || []);
        sortedToplevels = isNiri ? NiriService.sortToplevels(values) : values;
        toplevelsChanged();
    }

    function getScreenScale(screen) {
        if (!screen)
            return 1;
        if (isNiri) {
            const scale = NiriService.displayScales?.[screen.name];
            if (scale !== undefined && scale > 0)
                return scale;
            return screen.devicePixelRatio || 1;
        }
        const monitor = Hyprland.monitors?.values?.find(m => m.name === screen.name);
        if (monitor?.scale !== undefined)
            return monitor.scale;
        return screen.devicePixelRatio || 1;
    }

    function getFocusedScreen() {
        const screenName = isNiri
            ? NiriService.currentOutput
            : (Hyprland.focusedWorkspace?.monitor?.name || Hyprland.focusedMonitor?.name || "");
        if (screenName) {
            for (let i = 0; i < Quickshell.screens.length; i++) {
                if (Quickshell.screens[i].name === screenName)
                    return Quickshell.screens[i];
            }
        }
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }

    function _hyprForToplevel(toplevel) {
        const list = Array.from(Hyprland.toplevels?.values || []);
        for (let i = 0; i < list.length; i++) {
            const h = list[i];
            if (h.wayland === toplevel || h.address === toplevel?.address || h.title === toplevel?.title)
                return h;
        }
        return null;
    }

    function _activeWorkspaceIdForScreen(screenName) {
        if (screenName) {
            const mon = Hyprland.monitors?.values?.find(m => m.name === screenName);
            if (mon?.activeWorkspace?.id !== undefined)
                return mon.activeWorkspace.id;
        }
        return Hyprland.focusedWorkspace?.id || 1;
    }

    function filterCurrentWorkspace(toplevels, screenName) {
        if (isNiri)
            return NiriService.filterCurrentWorkspace(toplevels, screenName);
        const activeWs = _activeWorkspaceIdForScreen(screenName);
        return Array.from(toplevels || []).filter(t => {
            const h = _hyprForToplevel(t);
            if (!h)
                return true;
            return h.workspace?.id === activeWs;
        });
    }

    function filterCurrentDisplay(toplevels, screenName) {
        if (isNiri)
            return NiriService.filterCurrentDisplay(toplevels, screenName);
        if (!screenName)
            return Array.from(toplevels || []);
        return Array.from(toplevels || []).filter(t => {
            const h = _hyprForToplevel(t);
            if (!h)
                return true;
            return h.monitor?.name === screenName || h.workspace?.monitor?.name === screenName;
        });
    }

    function hyprlandDockOverlapForSmartAutoHide(screen, edge) { return false; }
    function mangoDockOverlapForSmartAutoHide(screen, edge) { return false; }

    function powerOffMonitors() {
        if (isNiri)
            return NiriService.powerOffMonitors();
        if (isHyprland)
            return HyprlandService.dpmsOff();
        log.warn("Cannot power off monitors: compositor is", compositor);
        return false;
    }
    function powerOnMonitors() {
        if (isNiri)
            return NiriService.powerOnMonitors();
        if (isHyprland)
            return HyprlandService.dpmsOn();
        log.warn("Cannot power on monitors: compositor is", compositor);
        return false;
    }
    // Request an asynchronous monitor refresh before reading lastIpcObject.
    function refreshMonitors() {
        if (isNiri)
            return NiriService.fetchOutputs();
        if (isHyprland)
            Hyprland.refreshMonitors();
    }
    // True if the compositor reports any connected display currently powered off
    // (DPMS). Used for restart recovery + out-of-band reconcile. Returns false
    // when unknown. NB: quickshell 0.3's HyprlandMonitor has no dpmsStatus
    // property — it only surfaces the raw hyprctl JSON via lastIpcObject.
    function anyDisplayOff() {
        if (isNiri)
            return NiriService.anyDisplayOff();
        const mons = Hyprland.monitors?.values ?? [];
        return mons.some(m => m?.lastIpcObject?.dpmsStatus === false);
    }
    function debugDisplayStates() {
        if (isNiri)
            return NiriService.debugDisplayStates();
        const mons = Hyprland.monitors?.values ?? [];
        return "monitors=[" + mons.map(m => (m?.name ?? "?") + ":" + (m?.lastIpcObject?.dpmsStatus)).join(",") + "]";
    }

    // The helper resolves the owner of Quickshell's actual Wayland socket and
    // liveness-checks compositor IPC fallbacks. Keep procfs parsing out of QML.
    function detectCompositor() {
        Proc.runCommand("compositor-current",
            [Paths.vshellCli, "compositor", "current", "--json"],
            (output, exitCode) => {
                if (exitCode !== 0) {
                    log.warn("Compositor detection helper failed with exit code", exitCode);
                    _applyCompositor("unknown");
                    return;
                }
                try {
                    const result = JSON.parse(output);
                    const name = result.compositor || "unknown";
                    _applyCompositor(name === "hyprland" || name === "niri" ? name : "unknown");
                    log.info("Detected", compositor, "from", result.source || "helper");
                } catch (error) {
                    log.warn("Failed to parse compositor detection result:", error);
                    _applyCompositor("unknown");
                }
        }, 0, 3000);
    }

    function _applyCompositor(name) {
        isHyprland = name === "hyprland";
        isNiri = name === "niri";
        compositor = name;
        compositorDetected = true;
        refreshToplevels();
        seedRememberedFocus();
    }
}
