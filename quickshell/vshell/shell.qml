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

    readonly property bool runGreeter: Quickshell.env("VSHELL_RUN_GREETER") === "1" || Quickshell.env("VSHELL_RUN_GREETER") === "true"
    readonly property bool disableHotReload: Quickshell.env("VSHELL_DISABLE_HOT_RELOAD") === "1" || Quickshell.env("VSHELL_DISABLE_HOT_RELOAD") === "true"

    // Duplicate-instance guard. A second full VGS shell on the same Wayland
    // session fights the first one for session-global resources — WlSessionLock,
    // the fade-to-lock overlay, the idle/DPMS tiers — and leaves orphaned
    // full-screen layer surfaces behind when it is killed. Validation must use
    // scripts/qml-smoke.sh; this is the runtime backstop for someone who runs
    // `qs -c vshell` or `qs -p quickshell/vshell` by hand rather than the script.
    //
    // Only a shell that a live peer *provably* predates ever yields, and every
    // unknown (no CLI, no registry, unprovable age, slow answer) fails open, so
    // this can never keep the session shell from starting.
    //
    // The verdict gates the load rather than only tearing a duplicate down
    // afterwards: a shell that loads first would already have built its bar,
    // dock, and fade-to-lock surfaces and could win WlSessionLock before the
    // teardown lands, which is the damage this guard exists to avoid. The cost
    // is one subprocess round trip on the startup path — measured at ~0.13 s
    // warm, bounded by the 2 s deadline below — during which nothing is drawn.
    //
    // Hot reload rebuilds this tree in the *same* process, which already passed
    // the check and already owns the session; re-running it there would only add
    // latency and a needless window with no shell loaded. Only a freshly started
    // process consults the guard.
    // Biased towards "fresh": misreading a slow cold start as a reload would
    // silently drop the guard, while re-running it on an unusually early reload
    // only costs that one reload a moment with nothing loaded.
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

    // Every give-up path says why. A guard that quietly stops working looks
    // exactly like "no duplicate found", which would hide the regression this
    // whole mechanism exists to catch.
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

        // StdioCollector is fully populated by the time exited() fires, verified
        // against Quickshell 0.3.0; the exit code has to be read here, so this
        // does not use onStreamFinished like the read-only collectors elsewhere.
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

        // A command that never starts emits no exited(), which would otherwise
        // leave the shell dark until the deadline below. exited() is emitted
        // before running goes false (verified on Quickshell 0.3.0), so a normal
        // run has always resolved by the time this fires.
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

    // The session lock is the one part of the shell that must NOT sit under a
    // Loader. `ReloadPropagator` hands old instances only to children that are
    // themselves `Reloadable`, and a `Loader` is not one, so reload matching
    // stops dead at the loaders below and everything under them is rebuilt from
    // nothing. For `WlSessionLock` that orphans the manager that owns the
    // ext-session-lock and poisons every later lock request in this process (the
    // full mechanism is documented in Modules/Lock/Lock.qml). A `Scope` IS a
    // ReloadPropagator, so as a direct ShellRoot child the lock is matched
    // positionally across generations and survives a hot reload intact.
    //
    // It is therefore always built — even in the greeter, and even in a shell
    // the duplicate guard is about to refuse. `active` gates the behaviour
    // instead: an inactive Lock takes no lock, and registers no lock IPC.
    Lock {
        active: !entrypoint.runGreeter && entrypoint.shellAllowed
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
