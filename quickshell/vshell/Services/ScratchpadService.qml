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

    // Set when a run produces a payload with ok:true. A run that ends without
    // one — non-zero exit, unparseable output, or a binary that never started —
    // must not leave the previous success standing.
    property bool _applyAnswered: false
    property int _applyExitCode: 0
    property string _applyError: ""
    property bool _statusAnswered: false

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

    // Move a pad's window back to the active workspace. Called just before a pad
    // is deleted, so its window is never stranded on a special workspace that
    // no longer has a keybind or a rule pointing at it. The class regex is
    // passed in because the caller is about to rewrite the settings the helper
    // would otherwise read it from.
    function release(padId, classRegex) {
        if (!supported || !padId)
            return;
        const argv = [Paths.vshellCli, "scratchpad", "release", String(padId)];
        if (classRegex)
            argv.push("--class-regex", String(classRegex));
        Quickshell.execDetached(argv);
    }

    Component.onCompleted: refreshStatus()

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
