pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// Scratchpads: apps parked on hidden special workspaces that one keybind slides
// in and out. This service is a thin seam onto `vshell scratchpad ...` — every
// piece of real work (percentage resolution, config generation, the runtime
// toggle) lives in bin/vshell-helper, because generating compositor config is
// exactly the "heavy work / large template renderer" that must not sit in QML.
//
// See docs/architecture/scratchpads.md.
Singleton {
    id: root
    readonly property var log: Log.scoped("ScratchpadService")

    // Hyprland is the reference implementation and the only one wired up; Niri
    // has no special workspaces and needs its own generator. The helper refuses
    // there too — this flag only keeps the UI honest about it rather than being
    // the thing that enforces it.
    readonly property bool supported: CompositorService.isHyprland

    // Last known generation result, so the Settings page can show whether the
    // generated file is actually included by hyprland.lua without shelling out
    // again on every repaint.
    property var status: ({
            "included": false,
            "includeLine": "",
            "statusMessage": "",
            "path": "",
            "monitorsResolved": true
        })
    property bool applying: false
    property bool _applyPending: false

    // Why the last apply failed, or "" when it succeeded. A failed apply used
    // to leave the previous status on screen and say nothing, so the page kept
    // reporting rules that were never written.
    property string lastError: ""

    // Pads the helper could not use, each with the reason. A rejected pad
    // generates no rules at all, so without surfacing these a scratchpad broken
    // by a hand-edited settings.json would simply stop working while the page
    // went on showing it as configured.
    property var problems: []

    // Set when a run produces a payload with ok:true. A run that ends without
    // one — non-zero exit, unparseable output, or a binary that never started —
    // must not leave the previous success standing.
    property bool _applyAnswered: false
    property int _applyExitCode: 0
    property string _applyError: ""
    property bool _statusAnswered: false
    property var _releaseCallback: null
    property bool _releaseAnswered: false
    property string _releaseError: ""

    function generateConfig() {
        if (!supported)
            return;
        applyTimer.restart();
    }

    // Debounced for the same reason the layout apply is: the Settings page
    // writes several fields in a row while the user drags a slider, and each
    // write would otherwise reload the compositor.
    Timer {
        id: applyTimer
        interval: 420
        repeat: false
        onTriggered: root.applyConfig()
    }

    function applyConfig() {
        if (!supported)
            return;
        if (applyProc.running) {
            root._applyPending = true;
            return;
        }
        root.applying = true;
        root._applyAnswered = false;
        root._applyExitCode = 0;
        applyProc.command = [Paths.vshellCli, "scratchpad", "apply", "--json"];
        applyProc.running = true;

        // Quickshell reports a command that cannot start by leaving `running`
        // false right here, and in that case neither `exited` nor
        // `onRunningChanged` ever fires — so without this check `applying`
        // would stay true for the rest of the session and every queued
        // regeneration would be stranded behind it.
        if (!applyProc.running)
            root._finishApply("scratchpad helper could not be started");
    }

    // One completion path for every way an apply can end. Called from the
    // running->false transition (the ordinary case, and the one that covers a
    // process which exits without `exited` being useful) and from the
    // failed-to-start check above.
    function _finishApply(error) {
        root.applying = false;
        root.lastError = error || "";
        if (error)
            log.warn("scratchpad apply failed:", error);
        if (root._applyPending) {
            root._applyPending = false;
            root.generateConfig();
        }
    }

    function refreshStatus() {
        if (!supported)
            return;
        root._statusAnswered = false;
        statusProc.command = [Paths.vshellCli, "scratchpad", "status"];
        statusProc.running = true;
        if (!statusProc.running)
            log.warn("scratchpad status helper could not be started");
    }

    // Reveal/hide a pad from the shell (a bar widget, an IPC caller). The same
    // command the generated keybind runs, so there is one toggle path and not
    // two that can drift.
    function toggle(padId) {
        if (!supported || !padId)
            return;
        Quickshell.execDetached([Paths.vshellCli, "scratchpad", "toggle", String(padId)]);
    }

    // ---- dismissOnFocusLoss ------------------------------------------------
    //
    // Hide a pad when focus leaves it. The subscription is NOT ours: compositor
    // focus has exactly one owner in this shell, CompositorService, which
    // attaches to Quickshell's process-wide `ToplevelManager` / `Hyprland`
    // singletons. This service reads two facts it publishes — which special
    // workspaces are on screen, and where the focused window lives — and never
    // opens an event subscription of its own. See docs/architecture/scratchpads.md.
    //
    // `hide`, not `toggle`: a toggle evaluated against state that has moved on
    // would REVEAL the pad the user just dismissed. The direction is never
    // inferred here.
    // The trigger is the focus TRANSITION off a pad's workspace, not "the pad
    // is visible and unfocused". Visibility would have to come from a monitor's
    // special-workspace field, which Quickshell only refreshes on request and
    // asynchronously — so it is stale at precisely the moment a pad is being
    // revealed or hidden. Where the focused window lives is maintained live
    // from the event socket instead, and a window's workspace does not change
    // when focus moves, so the two values being compared are both settled.
    // NOT filtered on `enabled`. Dismissal only ever HIDES, and hiding a
    // disabled pad is exactly what must keep working: disabling a pad while it
    // is on screen would otherwise strand it visible with no keybind left to
    // dismiss it. The helper allows the same thing for the same reason, and
    // skipping disabled pads here would put the two halves in disagreement.
    readonly property var dismissOnFocusLossPads: (SettingsData.scratchpads || []).filter(pad => pad && pad.dismissOnFocusLoss)

    property string _lastFocusedWorkspace: ""
    // Every pad awaiting dismissal, not just the most recent. On multiple
    // monitors two pads can be on screen at once, and focus can leave both
    // before the settle delay expires; keeping one id silently dropped the
    // other dismissal.
    property var _pendingDismissIds: []

    Connections {
        target: CompositorService
        function onActiveWorkspaceNameChanged() { root._onFocusMoved(); }
    }

    function _onFocusMoved() {
        if (!supported)
            return;
        const now = CompositorService.activeWorkspaceName;
        // "" is "the compositor did not tell us", which is not the same as
        // "focus is elsewhere". Dismissing on unknown would make a pad vanish
        // on any hiccup, and remembering unknown would erase where focus
        // actually was, so an unknown is skipped entirely.
        if (!now)
            return;
        const previous = root._lastFocusedWorkspace;
        root._lastFocusedWorkspace = now;
        if (!previous || previous === now)
            return;
        const pad = root.dismissOnFocusLossPads.find(p => "special:" + p.id === previous);
        if (!pad)
            return;
        const padId = String(pad.id);
        if (!root._pendingDismissIds.includes(padId))
            root._pendingDismissIds = root._pendingDismissIds.concat([padId]);
        dismissTimer.restart();
    }

    // Revealing a pad moves focus twice — `focusmonitor`, then `focuswindow` —
    // so for an instant focus has left the pad's workspace while the reveal is
    // still in progress. Acting then would dismiss the pad the keybind is in
    // the middle of showing. The condition is re-read when the delay expires
    // rather than trusted from when it started.
    Timer {
        id: dismissTimer
        interval: 250
        repeat: false
        onTriggered: {
            const pending = root._pendingDismissIds;
            root._pendingDismissIds = [];
            if (pending.length === 0)
                return;
            const focused = CompositorService.activeWorkspaceName;
            // Same rule as on the way in, and it has to hold here too: an
            // unknown focus is not "focus is elsewhere". Treating it as such
            // dismissed every pending pad on any hiccup — which is the exact
            // thing the entry path refuses to do.
            if (!focused) {
                root.log.debug("Focus is unknown at expiry; dismissing nothing");
                return;
            }
            for (const padId of pending) {
                if (focused === "special:" + padId)
                    continue;  // focus came back; the reveal was still settling
                root.log.debug("Dismissing", padId, "on focus loss");
                // `hide`, never `toggle`: a toggle decides direction from state
                // read a moment ago, so evaluated late it reveals the pad the
                // user just put away. The helper re-checks under the pad's lock
                // and treats an already-hidden pad as a no-op.
                Quickshell.execDetached([Paths.vshellCli, "scratchpad", "hide", padId]);
            }
        }
    }

    // Move a pad's window back to the active workspace, and report whether it
    // worked. Called just before a pad is deleted, so its window is never
    // stranded on a special workspace that no longer has a keybind or a rule
    // pointing at it.
    //
    // Both match criteria are passed in rather than looked up: the caller is
    // about to rewrite the settings the helper would read them from, and they
    // travel together because releasing on the class alone would drag a
    // same-class window the user excluded from the pad onto their active
    // workspace. Release must own exactly the windows the placement rule owned.
    //
    // NOT execDetached: the caller deletes the record only if this succeeds, so
    // the result has to come back. A discarded result meant the record was
    // deleted whether or not the window ever moved.
    function release(padId, classRegex, titleExclude, onDone) {
        if (!supported || !padId) {
            if (onDone)
                onDone(false, "scratchpads are not supported on this compositor");
            return;
        }
        if (releaseProc.running) {
            if (onDone)
                onDone(false, "another release is still running");
            return;
        }
        root._releaseCallback = onDone || null;
        root._releaseAnswered = false;
        root._releaseError = "";
        const argv = [Paths.vshellCli, "scratchpad", "release", String(padId), "--json"];
        if (classRegex)
            argv.push("--class-regex", String(classRegex));
        if (titleExclude)
            argv.push("--title-exclude", String(titleExclude));
        releaseProc.command = argv;
        releaseProc.running = true;
        if (!releaseProc.running)
            root._finishRelease(false, "scratchpad helper could not be started");
    }

    function _finishRelease(ok, error) {
        const callback = root._releaseCallback;
        root._releaseCallback = null;
        if (callback)
            callback(ok, error || "");
    }

    Component.onCompleted: {
        // Seed the remembered workspace, so a service constructed while focus
        // is already on a pad does not miss that pad's first transition:
        // without it the first `_onFocusMoved` had no `previous` to compare
        // against and threw the transition away.
        root._lastFocusedWorkspace = CompositorService.activeWorkspaceName;
        refreshStatus();
    }

    Process {
        id: applyProc
        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: {
                if ((text || "").trim().length === 0)
                    return;
                try {
                    const payload = JSON.parse(text);
                    if (!payload.ok) {
                        // ok:false is a real failure even on exit 0 — the
                        // unsupported-compositor refusal takes that shape.
                        root._applyError = payload.error || payload.reload?.stderr || "apply reported failure";
                        return;
                    }
                    root._applyAnswered = true;
                    root._applyError = "";
                    root.problems = payload.problems || [];
                    root.status = Object.assign({}, payload.include || {}, {
                        "path": payload.path || "",
                        "monitorsResolved": payload.scratchpads?.monitorsResolved !== false
                    });
                } catch (e) {
                    root._applyError = "helper returned invalid JSON";
                    log.warn("scratchpad apply returned invalid JSON:", e);
                }
            }
        }

        // `exited` fires BEFORE `running` goes false, so it is only used to
        // record the code. Completion is handled on the running->false
        // transition, which is the one signal that also arrives for a process
        // that produced no usable output.
        onExited: exitCode => root._applyExitCode = exitCode

        onRunningChanged: {
            if (running)
                return;
            if (root._applyExitCode !== 0)
                root._finishApply(root._applyError || ("helper exited with code " + root._applyExitCode));
            else if (!root._applyAnswered)
                root._finishApply(root._applyError || "helper produced no result");
            else
                root._finishApply("");
        }
    }

    Process {
        id: releaseProc
        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: {
                if ((text || "").trim().length === 0)
                    return;
                try {
                    const payload = JSON.parse(text);
                    root._releaseAnswered = payload.ok === true;
                    if (payload.ok !== true)
                        root._releaseError = payload.error || "release reported failure";
                } catch (e) {
                    root._releaseError = "helper returned invalid JSON";
                    log.warn("scratchpad release returned invalid JSON:", e);
                }
            }
        }

        // Same completion shape as the apply process, and for the same reason:
        // a helper that never starts emits no `exited`, and the caller is
        // waiting on this answer before it deletes anything.
        onRunningChanged: {
            if (running)
                return;
            if (root._releaseAnswered)
                root._finishRelease(true, "");
            else
                root._finishRelease(false, root._releaseError || "release produced no result");
        }
    }

    Process {
        id: statusProc
        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: {
                if ((text || "").trim().length === 0)
                    return;
                try {
                    const payload = JSON.parse(text);
                    root._statusAnswered = true;
                    root.problems = payload.problems || [];
                    root.status = Object.assign({}, payload.include || {}, {
                        "path": payload.path || "",
                        "monitorsResolved": payload.monitorsResolved !== false
                    });
                } catch (e) {
                    log.warn("scratchpad status returned invalid JSON:", e);
                }
            }
        }

        // Same reasoning as the apply process: a status query that produced no
        // answer must not leave the previous one standing as though it were
        // fresh, because the include banner is drawn from it.
        onRunningChanged: {
            if (running || root._statusAnswered)
                return;
            log.warn("scratchpad status produced no result; include state is unknown");
        }
    }
}
