//@ pragma Env QSG_RENDER_LOOP=threaded
//@ pragma Env QT_MEDIA_BACKEND=ffmpeg
//@ pragma Env QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi
//@ pragma Env QT_FFMPEG_ENCODING_HW_DEVICE_TYPES=vaapi
//@ pragma Env QT_WAYLAND_DISABLE_WINDOWDECORATION=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Material
//@ pragma UseQApplication
//@ pragma AppId com.vanillagreen.vshell

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Modules.Lock

ShellRoot {
    id: entrypoint

    // Keep Lock as the first direct child: reload propagation matches child indices, not reloadableId. scripts/check-lock-reload-order.py enforces the order.
    // Moving it can discard the live session-lock manager during reload. Loaders stop reload propagation.
    // The active gate prevents an inactive Lock from taking the lock or registering lock IPC.
    Lock {
        active: !entrypoint.runGreeter && entrypoint.shellAllowed
    }


    readonly property bool runGreeter: Quickshell.env("VSHELL_RUN_GREETER") === "1" || Quickshell.env("VSHELL_RUN_GREETER") === "true"
    readonly property bool disableHotReload: Quickshell.env("VSHELL_DISABLE_HOT_RELOAD") === "1" || Quickshell.env("VSHELL_DISABLE_HOT_RELOAD") === "true"

    // Check for a provably older live peer before loading session-global resources.
    // Unknown peer state permits startup; the deadline bounds the wait.
    // Skip the probe on hot reload because the same process already owns those resources.
    // Bias toward fresh: a false reload skips the guard, a false fresh only costs one probe.
    readonly property bool isReload: {
        const launched = Quickshell.launchTime;
        if (!launched)
            return false;
        return Date.now() - launched.getTime() > 30000;
    }
    readonly property bool guardDisabled: runGreeter || isReload || Quickshell.env("VSHELL_DISABLE_INSTANCE_GUARD") === "1" || Quickshell.env("VSHELL_DISABLE_INSTANCE_GUARD") === "true"
    property bool guardResolved: false
    property bool guardDuplicate: false
    readonly property bool shellAllowed: (guardDisabled || guardResolved) && !guardDuplicate

    // Report each inconclusive guard outcome so it remains distinct from confirmed peer absence.
    function failOpen(why: string): void {
        if (guardResolved)
            return;
        console.warn("VGS: duplicate-instance guard inconclusive:", why, "- starting normally");
        resolveGuard(false);
    }

    function resolveGuard(duplicate: bool): void {
        if (guardResolved)
            return;
        guardDuplicate = duplicate;
        guardResolved = true;
    }

    Component.onCompleted: {
        Quickshell.watchFiles = !disableHotReload;
    }

    Process {
        id: instanceGuard
        running: !entrypoint.guardDisabled
        // Paths owns the single definition of where bin/vshell lives; the guard
        // must not carry a second copy of that rule.
        command: [Paths.vshellCli, "instances", "guard", "--pid", String(Quickshell.processId), "--shell-id", Quickshell.shellId]

        // Read the collector with the exit code so the guard evaluates one completed process result.
        stdout: StdioCollector {
            id: guardOutput
        }

        onExited: exitCode => {
            if (exitCode !== 0) {
                entrypoint.failOpen(`${Paths.vshellCli} instances guard exited ${exitCode}`);
                return;
            }
            let verdict = null;
            try {
                verdict = JSON.parse(guardOutput.text);
            } catch (error) {
                entrypoint.failOpen("guard returned invalid JSON: " + error);
                return;
            }
            if (!verdict) {
                entrypoint.failOpen("guard returned an empty verdict");
                return;
            }
            if (verdict.duplicate !== true) {
                if (verdict.ok === false)
                    entrypoint.failOpen("instance registry unavailable: " + (verdict.error || verdict.reason));
                else
                    entrypoint.resolveGuard(false);
                return;
            }
            console.error("VGS: refusing to start a duplicate shell:", verdict.reason);
            console.error("VGS: run scripts/qml-smoke.sh for QML validation, or set VSHELL_DISABLE_INSTANCE_GUARD=1 to override.");
            entrypoint.resolveGuard(true);
        }

        // A failed start emits no exited signal. Handle its stopped state before the startup deadline.
        // exited() fires before running goes false on Quickshell 0.3.0, so a completed run has already resolved when this fires.
        onRunningChanged: {
            if (running || entrypoint.guardDisabled)
                return;
            entrypoint.failOpen("could not run " + Paths.vshellCli);
        }
    }

    // Quickshell 0.3.0 leaves QQmlEngine's quit()/exit() signals unconnected
    // ("Signal QQmlEngine::quit() emitted, but no receivers connected to handle
    // it"), so Qt.quit() does not end the process and QML has no way out except
    // signalling its own pid. Repeat it so one failed detach cannot strand a
    // shell that has already refused to draw anything.
    Timer {
        interval: 1000
        repeat: true
        triggeredOnStart: true
        running: entrypoint.guardDuplicate
        onTriggered: Quickshell.execDetached(["sh", "-c", `kill -TERM ${Quickshell.processId}`])
    }

    // The guard must never be able to hang startup: answer or not, the shell
    // comes up.
    Timer {
        interval: 2000
        running: !entrypoint.guardDisabled && !entrypoint.guardResolved
        onTriggered: entrypoint.failOpen("no answer within 2s")
    }

    Loader {
        id: vshellLoader
        asynchronous: false
        sourceComponent: VGS {}
        active: !entrypoint.runGreeter && entrypoint.shellAllowed
    }

    Loader {
        id: greeterLoader
        asynchronous: false
        sourceComponent: VGSGreeter {}
        active: entrypoint.runGreeter
    }
}
