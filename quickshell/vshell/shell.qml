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

ShellRoot {
    id: entrypoint

    readonly property bool runGreeter: Quickshell.env("VSHELL_RUN_GREETER") === "1" || Quickshell.env("VSHELL_RUN_GREETER") === "true"
    readonly property bool disableHotReload: Quickshell.env("VSHELL_DISABLE_HOT_RELOAD") === "1" || Quickshell.env("VSHELL_DISABLE_HOT_RELOAD") === "true"

    // Duplicate-instance guard. A second full VGS shell on the same Wayland
    // session fights the first one for session-global resources — WlSessionLock,
    // the fade-to-lock overlay, the idle/DPMS tiers — and leaves orphaned
    // full-screen layer surfaces behind when it is killed. Validation must use
    // scripts/qml-smoke.sh; this is the runtime backstop for a hand-run
    // `qs -c vshell` / `qs -p quickshell/vshell`.
    //
    // Only a shell that is *younger* than the owning instance ever yields, and
    // every unknown (no CLI, no registry, slow answer) fails open, so this can
    // never keep the session shell from starting.
    readonly property bool guardDisabled: runGreeter || Quickshell.env("VSHELL_DISABLE_INSTANCE_GUARD") === "1" || Quickshell.env("VSHELL_DISABLE_INSTANCE_GUARD") === "true"
    // Quickshell serves QML from a virtual filesystem, so Qt.resolvedUrl() here
    // yields qrc:/qs-blackhole, not a runnable path. shellDir is the real launch
    // directory, and `..` resolves *through* the ~/.config/quickshell/vshell
    // symlink when the kernel walks the path, so this works for a source
    // checkout, a packaged install, and a hand-run `qs -c vshell` alike.
    readonly property string vshellCli: {
        const root = Quickshell.env("VSHELL_ROOT");
        if (root)
            return root + "/bin/vshell";
        return Quickshell.shellDir + "/../../bin/vshell";
    }
    property bool guardResolved: false
    property bool guardDuplicate: false
    readonly property bool shellAllowed: (guardDisabled || guardResolved) && !guardDuplicate

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
        command: [entrypoint.vshellCli, "instances", "guard", "--pid", String(Quickshell.processId), "--shell-id", Quickshell.shellId]

        stdout: StdioCollector {
            id: guardOutput
        }

        onExited: exitCode => {
            if (exitCode !== 0) {
                entrypoint.resolveGuard(false);
                return;
            }
            let verdict = null;
            try {
                verdict = JSON.parse(guardOutput.text);
            } catch (error) {
                entrypoint.resolveGuard(false);
                return;
            }
            if (!verdict || verdict.duplicate !== true) {
                entrypoint.resolveGuard(false);
                return;
            }
            console.error("VGS: refusing to start a duplicate shell:", verdict.reason);
            console.error("VGS: run scripts/qml-smoke.sh for QML validation, or set VSHELL_DISABLE_INSTANCE_GUARD=1 to override.");
            entrypoint.resolveGuard(true);
            Quickshell.execDetached(["sh", "-c", `kill -TERM ${Quickshell.processId}`]);
        }
    }

    // The guard must never be able to hang startup: answer or not, the shell
    // comes up.
    Timer {
        interval: 2000
        running: !entrypoint.guardDisabled && !entrypoint.guardResolved
        onTriggered: entrypoint.resolveGuard(false)
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
