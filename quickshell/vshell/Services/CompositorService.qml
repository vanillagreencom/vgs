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

    // Which source the focus properties below resolve from. FOUR states, and the
    // `isHyprland`/`isNiri` pair cannot hold them: both booleans are false
    // BEFORE detection has answered and again when it answered "cannot tell", so
    // anything reading them directly resolves those two states through the
    // Hyprland branch — silently, and at exactly the moment paste is first used.
    //
    //   "pending"   detection has not answered yet. It always ends: this state
    //               is left by `_applyCompositor`, which `detectCompositor`
    //               reaches on every path, and its `Proc.runCommand` timeout is
    //               specified to fire the callback rather than wait on the
    //               process. So a consumer may WAIT for it, and nothing here
    //               needs a second deadline watching the first.
    //   "hyprland"  detection answered Hyprland.
    //   "niri"      detection answered Niri.
    //   "unknown"   detection answered that it could not tell — the helper
    //               failed, timed out, or named a compositor VGS does not
    //               support.
    //
    // What each state RESOLVES TO is decided in the two properties below and
    // stated there. The point of this property is that those are decisions a
    // reader can find and disagree with, rather than consequences of a boolean's
    // default value.
    readonly property string focusSource: !compositorDetected
        ? "pending"
        : (isNiri ? "niri" : (isHyprland ? "hyprland" : "unknown"))

    // The focused window's app id, or "" when nothing is focused, the compositor
    // does not report one, or none is known yet. "" means "unknown", not "no
    // app"; `focusSource` is what tells a consumer which kind of unknown.
    //
    // Per compositor, deliberately. On Hyprland this is the seat's active
    // toplevel, which the compositor drives through wlr-foreign-toplevel. Niri
    // does not populate that the same way — everywhere else in this file Niri
    // activation is derived from `NiriService.windows[].is_focused` rather than
    // from the active toplevel (see `NiriService.sortToplevels`), and consumers
    // of focus already skip `activeToplevelChanged` there in favour of Niri's
    // own events — so the Niri branch reads Niri's IPC-maintained focus. The
    // Hyprland path is untouched: this is additive, per AGENTS.md § Mission.
    //
    // PENDING resolves to "", not to the Hyprland branch. A target resolved
    // before detection answers is a guess, and the cost of guessing wrong is the
    // stray input this whole path exists to prevent. The consumer that cares
    // waits — PasteService queues the paste rather than pressing a chord it
    // cannot justify, which is the same rule it already applies to a helper in
    // flight and to an unconfirmed seat.
    //
    // UNKNOWN resolves through the Hyprland branch, deliberately, and this is
    // the decision most worth disagreeing with. Three things argue for it: it is
    // what every target did before VGS-119, so a detection failure degrades to
    // the old behaviour instead of taking paste away; the Niri branch has
    // nothing to offer here anyway, because `NiriService` only connects its
    // socket once `isNiri` is true, so a failed detection leaves Niri's own
    // focus source empty; and refusing instead would disable paste for every
    // Hyprland user over one failed helper exec while still giving a Niri user
    // nothing. The cost is real and named: on Niri with detection broken, a
    // terminal gets Ctrl+V — the original bug. Detection failing is already
    // logged as a warning where it happens.
    readonly property string focusedAppId: focusSource === "niri"
        ? ((NiriService.windows ?? []).find(window => window.is_focused)?.app_id ?? "")
        : (focusSource === "pending" ? "" : (ToplevelManager.activeToplevel?.appId ?? ""))

    // The app id of the window that last held focus, for consumers that need a
    // target across the gaps where `focusedAppId` is "": a shell surface taking
    // keyboard focus clears the seat's active toplevel (and, on Niri, leaves no
    // window with `is_focused`), and focus returns asynchronously.
    //
    // Gated on that window still being alive, so it empties again the moment it
    // closes. Held unconditionally it would name a window that is gone, and a
    // consumer would act on a dead target — for paste, injecting a terminal's
    // keystroke into whatever replaced it. Each branch's gate is the live list
    // its own compositor maintains: membership in `ToplevelManager.toplevels`
    // for Hyprland, and for Niri the lookup itself, since `NiriService.windows`
    // drops a window on `WindowClosed`. Pending and unknown resolve exactly as
    // they do for the live value above, for the same reasons: a remembered
    // window is still a target, and naming one from a compositor nobody has
    // confirmed yet is still a guess.
    property var _lastFocusedToplevel: null
    property var _lastFocusedNiriWindowId: null
    readonly property string lastFocusedAppId: focusSource === "niri"
        ? ((NiriService.windows ?? []).find(window => window.id === _lastFocusedNiriWindowId)?.app_id ?? "")
        : (focusSource === "pending" ? "" : (_lastFocusedToplevel && (ToplevelManager.toplevels?.values ?? []).includes(_lastFocusedToplevel) ? (_lastFocusedToplevel.appId ?? "") : ""))

    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() {
            if (ToplevelManager.activeToplevel)
                root._lastFocusedToplevel = ToplevelManager.activeToplevel;
        }
    }

    // The Niri half of the same remembering. Runs off `NiriService.windows`,
    // which is reassigned on every focus event, and records only when a window
    // actually holds focus — recording the absence would overwrite the target a
    // consumer is about to need.
    function rememberNiriFocus() {
        const focused = (NiriService.windows ?? []).find(window => window.is_focused);
        if (focused)
            root._lastFocusedNiriWindowId = focused.id;
    }

    // Focus that was ALREADY in place when this service was constructed fires no
    // change signal, so the listeners above never see it and the remembered
    // target stays empty until focus next moves. The first paste after startup
    // would then find no target — and a shell surface taking keyboard focus is
    // itself what empties the live value — so a terminal would get Ctrl+V, which
    // is the stray-input bug this whole path exists to prevent, at the moment a
    // user forms their opinion of it. Read the state that is already there
    // instead of waiting for a transition that may have happened first.
    //
    // Runs twice, deliberately. At construction `isNiri` is still false, because
    // compositor detection is asynchronous, so only the Hyprland half is
    // reachable then; the second call sits where detection lands, which is also
    // the moment the Niri listener starts having any effect.
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
        function onValuesChanged() { root.refreshToplevels(); }
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
        seedRememberedFocus();
    }
}
