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

    // THE question anything wanting focus should ask: can the focus source
    // answer a focus query right now? Not "has a flag been set" — three separate
    // bugs in this file came from asking that, each about a different flag, and
    // this property exists so there is one thing to be right about instead of a
    // growing row of them.
    //
    // Per state, and every condition named, including the ones VGS cannot see:
    //
    //   "pending"   NOT ready. Detection has not named a source, so there is no
    //               source to ask. Ends on its own: `detectCompositor` reaches
    //               `_applyCompositor` on every path, under a Proc timeout that
    //               fires the callback rather than waiting on the process.
    //
    //   "niri"      The event stream's link is up AND the window snapshot has
    //               arrived. Both are needed and neither implies the other:
    //               `NiriService.windows` starts as `[]` and stays that way
    //               until a WindowsChanged event lands, which is well after
    //               detection completes — a paste in that gap resolved no target
    //               and pasted Ctrl+V. Niri can afford a strict arm because it
    //               has the observable that settles the question below: an empty
    //               list AFTER a snapshot is niri saying "no windows", which is
    //               an answer, and an empty list before one is silence.
    //               NOT observable, and therefore NOT claimed: whether niri is
    //               actually answering. `eventStreamUp` says the unix socket is
    //               connected; a peer that accepted the connection and went
    //               quiet reads as up. The deadline in PasteService is what
    //               covers that, by refusing rather than waiting forever.
    //
    //   "hyprland"  Ready as soon as detection names the source. This is a
    //               DECISION, not an oversight, and it is the answer to: what
    //               does readiness mean on a source whose emptiness cannot be
    //               told apart from its silence?
    //
    //               It cannot be told apart here. wlr-foreign-toplevel delivers
    //               the existing windows when Quickshell binds the global, but
    //               `ToplevelManager` surfaces no signal for it — verified
    //               against Quickshell 0.3's own type information, which
    //               declares `toplevels` and `activeToplevel` and nothing else —
    //               so "no toplevel reported" is equally an empty session and a
    //               list that has not arrived. An earlier attempt gated this arm
    //               on having ever seen a toplevel, and that was a REGRESSION:
    //               on a seat with no windows open the condition never becomes
    //               true, so paste was refused outright on Hyprland where it had
    //               always worked. AGENTS.md § Mission requires Niri support to
    //               be additive, and that broke it.
    //
    //               So the ambiguity is resolved toward the answer VGS can give:
    //               no toplevel means NOTHING IS FOCUSED. That is a real answer,
    //               and it resolves "" and falls back to Ctrl+V exactly as every
    //               target did before VGS-119. The cost is named rather than
    //               hidden: a paste in the instants before the initial list
    //               arrives resolves no target, so a terminal gets Ctrl+V. That
    //               is the pre-VGS-119 behaviour, bounded to a window the
    //               remembered-focus seeding already covers whenever the list
    //               arrived before detection did — and unlike the alternative it
    //               takes nothing away that used to work.
    //
    //   "unknown"   Follows the Hyprland arm, on the same terms and for the same
    //               reason. Detection failing resolves through the toplevel path
    //               — decided and argued where that decision lives, on
    //               `focusedAppId` — so readiness is the same question there.
    //
    // Spelled as a test on `focusSource` rather than as a literal `true`,
    // deliberately: what the toplevel arm asserts is that a source has been
    // NAMED, which is a condition, not an assumption that some unobservable
    // thing has happened.
    readonly property bool focusReady: focusSource === "niri"
        ? (NiriService.eventStreamUp && NiriService.windowsSnapshotReceived)
        : focusSource !== "pending"

    // The focused window's app id, or "" when nothing is focused, the compositor
    // does not report one, or the source cannot answer yet. "" means "unknown",
    // not "no app"; `focusReady` is what tells a consumer which kind of unknown.
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
    // The first match is THE match: `NiriService.markFocusedWindow` keeps at
    // most one window carrying `is_focused`, so this `find()` is not choosing
    // between candidates. Without that invariant it would return whichever
    // window sorted first, which is how a background workspace's active window
    // once took a terminal's keystroke.
    //
    // A SOURCE THAT CANNOT ANSWER resolves to "" on either arm, which is one
    // rule rather than a list of the ways it can happen: detection still
    // pending, Niri's snapshot not yet delivered, no toplevel ever reported.
    // `focusReady` is that rule and the only gate here — a target named by a
    // source that has not answered is a guess, and the cost of guessing wrong is
    // the stray input this whole path exists to prevent. The consumer that cares
    // waits: PasteService queues the paste rather than pressing a chord it
    // cannot justify, the same rule it already applies to a helper in flight and
    // to an unconfirmed seat.
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
        ? (focusReady ? ((NiriService.windows ?? []).find(window => window.is_focused)?.app_id ?? "") : "")
        : (focusReady ? (ToplevelManager.activeToplevel?.appId ?? "") : "")

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
    // drops a window on `WindowClosed`. A source that cannot answer resolves
    // exactly as it does for the live value above, for the same reason: a
    // remembered window is still a target, and naming one from a source that has
    // not spoken is still a guess.
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
