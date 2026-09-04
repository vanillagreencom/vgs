pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// The helper owns scratchpad generation and runtime toggles; this service exposes those actions and results to QML.
Singleton {
    id: root
    readonly property var log: Log.scoped("ScratchpadService")

    // Hyprland uses special workspaces; Niri uses named workspaces.
    // The helper selects the backend, and this flag controls UI availability.
    readonly property bool supported: CompositorService.isHyprland || CompositorService.isNiri
    readonly property bool onNiri: CompositorService.isNiri

    // Settings that are stored and shown but cannot be honoured by the backend
    // that is actually running. Reported, never silently dropped — a control
    // that claims a mechanism the compositor does not have is worse than no
    // control. Populated from the helper, which is the only thing that knows.
    property var unsupported: []

    // Whether a given pad field does anything on this compositor. Settings uses
    // it to disable the control rather than let it set a value that is ignored.
    function fieldSupported(field) {
        for (const item of (unsupported || [])) {
            if (item && item.field === field && !item.id)
                return false;
        }
        return true;
    }

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

    // The last apply error, or an empty string after success.
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
    property var _hideCallback: null
    property bool _hideAnswered: false
    property string _hideError: ""
    property string _matchPadId: ""
    property bool _matchAnswered: false
    property var _matchQueue: []
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

    // Pattern matches by pad id: {state, count, error}.
    // Count is meaningful only for known state; unknown means no answer, and error means the pattern is invalid.
    property var matchStates: ({})

    function _setMatchState(padId, state, count, error) {
        const next = Object.assign({}, root.matchStates);
        next[padId] = {
            "state": state,
            "count": count || 0,
            "error": error || ""
        };
        root.matchStates = next;
    }

    function refreshMatches(padId, classRegex, titleExclude) {
        if (!supported || !padId || !classRegex)
            return;
        if (matchProc.running) {
            root._matchQueue = (root._matchQueue || []).concat([[padId, classRegex, titleExclude]]);
            return;
        }
        root._matchPadId = String(padId);
        root._matchAnswered = false;
        const argv = [Paths.vshellCli, "scratchpad", "match", "--json", "--class-regex", String(classRegex)];
        if (titleExclude)
            argv.push("--title-exclude", String(titleExclude));
        matchProc.command = argv;
        matchProc.running = true;

        // A command that cannot start leaves `running` false and emits neither
        // `exited` nor a stream finish, so the running->false handler never
        // fires: this request would never complete and every queued one behind
        // it would be stranded. Record the failure and keep the queue moving.
        if (!matchProc.running) {
            root._setMatchState(root._matchPadId, "unknown", 0, "");
            log.warn("scratchpad match helper could not be started");
            root._drainMatchQueue();
        }
    }

    function _drainMatchQueue() {
        const queued = root._matchQueue || [];
        if (queued.length === 0)
            return;
        root._matchQueue = queued.slice(1);
        root.refreshMatches(queued[0][0], queued[0][1], queued[0][2]);
    }

    function refreshStatus() {
        if (!supported)
            return;
        root._statusAnswered = false;
        statusProc.command = [Paths.vshellCli, "scratchpad", "status"];
        statusProc.running = true;
        // A failed start emits no exit or running transition; route it through completion so include state becomes unknown.
        if (!statusProc.running)
            root._markStatusUnknown("scratchpad status helper could not be started");
    }

    // `included: null` is the third state, distinct from false: the page says it
    // does not know, rather than picking one of the two answers it has no
    // evidence for. A stale `true` silences the include banner entirely.
    function _markStatusUnknown(reason) {
        log.warn(reason);
        root.status = Object.assign({}, root.status, {
            "included": null,
            "statusMessage": ""
        });
    }

    // Reveal/hide a pad from the shell (a bar widget, an IPC caller). The same
    // command the generated keybind runs, so there is one toggle path and not
    // two that can drift.
    function toggle(padId) {
        if (!supported || !padId)
            return;
        Quickshell.execDetached([Paths.vshellCli, "scratchpad", "toggle", String(padId)]);
    }

    // Use shared CompositorService focus transitions to hide pads when focus leaves their workspace.
    // Monitor visibility snapshots can be stale during a reveal.
    // Use hide rather than toggle, and permit dismissal of disabled pads so they cannot remain stranded on screen.
    readonly property var dismissOnFocusLossPads: (SettingsData.scratchpads || []).filter(pad => pad && pad.dismissOnFocusLoss)

    property string _lastFocusedWorkspace: ""
    // Keep every pending pad id because focus can leave pads on different monitors before the settle timer fires.
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
            // Unknown focus does not prove that focus left a pad; retain pending state until a usable answer arrives.
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
                // --keep-focus: the user picked where they wanted to be, and
                // that choice is what triggered this dismissal. A plain hide
                // restores whatever the pad was revealed FROM, which would yank
                // focus straight back out of the window they just moved to.
                Quickshell.execDetached([Paths.vshellCli, "scratchpad", "hide", padId, "--keep-focus"]);
            }
        }
    }

    // Move matching pad windows to the active workspace and return success before deleting the pad.
    // Pass class and title criteria together because settings may change before the helper reads them.
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

    // Hide a pad if it is on screen, and report whether that worked. Idempotent:
    // a pad that is already hidden succeeds without dispatching, so this can
    // never accidentally REVEAL one — which plain toggle semantics would.
    //
    // Settings calls this while disabling a pad, before the write that
    // regenerates config and removes the keybind. Hiding afterwards would be too
    // late: the keybind that was the user's way to dismiss it is already gone.
    function hide(padId, onDone) {
        if (!supported || !padId) {
            if (onDone)
                onDone(false, "scratchpads are not supported on this compositor");
            return;
        }
        if (hideProc.running) {
            if (onDone)
                onDone(false, "another hide is still running");
            return;
        }
        root._hideCallback = onDone || null;
        root._hideAnswered = false;
        root._hideError = "";
        hideProc.command = [Paths.vshellCli, "scratchpad", "hide", String(padId), "--json"];
        hideProc.running = true;
        if (!hideProc.running)
            root._finishHide(false, "scratchpad helper could not be started");
    }

    function _finishHide(ok, error) {
        const callback = root._hideCallback;
        root._hideCallback = null;
        if (callback)
            callback(ok, error || "");
    }

    function _finishRelease(ok, error) {
        const callback = root._releaseCallback;
        root._releaseCallback = null;
        if (callback)
            callback(ok, error || "");
    }

    Component.onCompleted: {
        // Seed current workspace at startup so the first focus transition has a previous workspace to compare.
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
                    root.unsupported = payload.scratchpads?.unsupported || [];
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
        id: hideProc
        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: {
                if ((text || "").trim().length === 0)
                    return;
                try {
                    const payload = JSON.parse(text);
                    root._hideAnswered = payload.ok === true;
                    if (payload.ok !== true)
                        root._hideError = payload.error || "hide reported failure";
                } catch (e) {
                    root._hideError = "helper returned invalid JSON";
                    log.warn("scratchpad hide returned invalid JSON:", e);
                }
            }
        }

        // Same completion shape as apply and release: a helper that never
        // starts emits no `exited`, and the caller is blocked on this answer
        // before it disables anything.
        onRunningChanged: {
            if (running)
                return;
            if (root._hideAnswered)
                root._finishHide(true, "");
            else
                root._finishHide(false, root._hideError || "hide produced no result");
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
        id: matchProc
        running: false
        command: []

        stdout: StdioCollector {
            onStreamFinished: {
                if ((text || "").trim().length === 0)
                    return;
                try {
                    const payload = JSON.parse(text);
                    root._matchAnswered = true;
                    if (payload.ok !== true) {
                        // A pattern that does not compile is an ERROR, not a
                        // count of zero. Carry the reason so the page can say
                        // the pattern is broken rather than that it works and
                        // matches nothing.
                        root._setMatchState(root._matchPadId, "error", 0,
                            payload.error || "the pattern could not be evaluated");
                    } else if (payload.known === false) {
                        root._setMatchState(root._matchPadId, "unknown", 0, "");
                    } else {
                        root._setMatchState(root._matchPadId, "known", payload.count || 0, "");
                    }
                } catch (e) {
                    root._setMatchState(root._matchPadId, "unknown", 0, "");
                    log.warn("scratchpad match returned invalid JSON:", e);
                }
            }
        }

        onRunningChanged: {
            if (running)
                return;
            // A run that ended without a parsed answer must not leave whatever
            // was there before standing as though it were fresh.
            if (!root._matchAnswered)
                root._setMatchState(root._matchPadId, "unknown", 0, "");
            root._drainMatchQueue();
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
                    root.unsupported = payload.unsupported || [];
                    root.status = Object.assign({}, payload.include || {}, {
                        "path": payload.path || "",
                        "monitorsResolved": payload.monitorsResolved !== false
                    });
                } catch (e) {
                    log.warn("scratchpad status returned invalid JSON:", e);
                }
            }
        }

        // Invalidate unanswered include queries with included: null so stale success cannot hide the include warning.
        onRunningChanged: {
            if (running || root._statusAnswered)
                return;
            root._markStatusUnknown("scratchpad status produced no result; include state is unknown");
        }
    }
}
