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
        applyProc.command = [Paths.vshellCli, "scratchpad", "apply", "--json"];
        applyProc.running = true;
    }

    function refreshStatus() {
        if (!supported)
            return;
        statusProc.command = [Paths.vshellCli, "scratchpad", "status"];
        statusProc.running = true;
    }

    // Reveal/hide a pad from the shell (a bar widget, an IPC caller). The same
    // command the generated keybind runs, so there is one toggle path and not
    // two that can drift.
    function toggle(padId) {
        if (!supported || !padId)
            return;
        Quickshell.execDetached([Paths.vshellCli, "scratchpad", "toggle", String(padId)]);
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
                        log.warn("scratchpad apply failed:", payload.error || payload.reload?.stderr || "unknown");
                        return;
                    }
                    root.status = Object.assign({}, payload.include || {}, {
                        "path": payload.path || "",
                        "monitorsResolved": payload.scratchpads?.monitorsResolved !== false
                    });
                } catch (e) {
                    log.warn("scratchpad apply returned invalid JSON:", e);
                }
            }
        }

        onExited: exitCode => {
            root.applying = false;
            if (exitCode !== 0)
                log.warn("scratchpad apply failed with code:", exitCode);
            if (root._applyPending) {
                root._applyPending = false;
                root.generateConfig();
            }
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
                    root.status = Object.assign({}, payload.include || {}, {
                        "path": payload.path || "",
                        "monitorsResolved": payload.monitorsResolved !== false
                    });
                } catch (e) {
                    log.warn("scratchpad status returned invalid JSON:", e);
                }
            }
        }
    }
}
