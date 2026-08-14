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

    // The workspace the focused window is on, or "" when it is not known.
    //
    // This service is the single seam onto compositor focus for the whole
    // shell. Nothing else may open a compositor subscription to learn about
    // focus: Quickshell's `Hyprland` and `ToplevelManager` are process-wide
    // singletons owning exactly one connection each, and this file is where VGS
    // attaches to them.
    //
    // Read from `Hyprland.activeToplevel`, which the singleton maintains from
    // the event socket, rather than re-derived from a monitor's `lastIpcObject`
    // — that one is documented as not updating until the object is fetched
    // again, and `refreshMonitors()` is asynchronous, so it is stale at exactly
    // the moment a focus change matters.
    //
    // Hyprland only, deliberately: Niri has no equivalent name here and the one
    // consumer (scratchpads) does not exist there at all — VGS-83. "" means
    // "unknown", and callers must treat it as such rather than as "somewhere
    // else".
    readonly property string activeWorkspaceName: isHyprland ? (Hyprland.activeToplevel?.workspace?.name ?? "") : ""

    // The focused window's app id, or "" when nothing is focused or the
    // compositor does not report one. Read from `ToplevelManager`, which both
    // supported compositors feed through wlr-foreign-toplevel, so this works on
    // Hyprland and Niri alike. "" means "unknown", not "no app".
    readonly property string focusedAppId: ToplevelManager.activeToplevel?.appId ?? ""

    Component.onCompleted: {
        detectCompositor();
        refreshToplevels();
        randrDataReady();
    }

    Connections {
        target: ToplevelManager.toplevels
        function onValuesChanged() { root.refreshToplevels(); }
    }

    Connections {
        target: NiriService
        function onWindowsChanged() {
            if (root.isNiri)
                root.refreshToplevels();
        }
        function onAllWorkspacesChanged() {
            if (root.isNiri)
                root.refreshToplevels();
        }
    }

    Connections {
        target: root.isHyprland ? Hyprland : null
        enabled: root.isHyprland
        function onRawEvent(event) {
            if (event.name === "openwindow" || event.name === "closewindow" || event.name === "movewindow" || event.name === "movewindowv2" || event.name === "workspace" || event.name === "workspacev2" || event.name === "focusedmon" || event.name === "focusedmonv2" || event.name === "activewindow" || event.name === "activewindowv2" || event.name === "changefloatingmode" || event.name === "fullscreen" || event.name === "moveintogroup" || event.name === "moveoutofgroup" || event.name === "activespecial") {
                try {
                    Hyprland.refreshToplevels();
                    Hyprland.refreshMonitors();
                } catch (e) {}
                root.refreshToplevels();
            }
        }
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
    // Ask quickshell to re-query `hyprctl monitors` (lastIpcObject is only as
    // fresh as the last refresh). Async — allow ~300ms before reading.
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
    }
}
