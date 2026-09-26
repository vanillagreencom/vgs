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

    // The process holding the session's instance lock names itself in VGS_RUNNER_PID: the runner, or flock in
    // bin/vshell's no-backend fallback. Every process the shell starts inherits that variable, so only the
    // holder's direct child draws. VSHELL_DISABLE_INSTANCE_GUARD admits an isolated sandbox with no lock holder;
    // no launch path of vshell run sets it.
    readonly property bool guardDisabled: runGreeter || Quickshell.env("VSHELL_DISABLE_INSTANCE_GUARD") === "1" || Quickshell.env("VSHELL_DISABLE_INSTANCE_GUARD") === "true"
    readonly property string runnerPid: Quickshell.env("VGS_RUNNER_PID") || ""
    readonly property string parentPid: parentPidOf(ownStat.text())
    readonly property bool shellAllowed: guardDisabled || launchedByRunner(parentPid, runnerPid)

    // stat is /proc/self/stat. The process name is parenthesised and may hold spaces or parentheses,
    // so fields are read after the last ')': state, then the parent pid. An unparseable read yields "".
    function parentPidOf(stat: string): string {
        const nameEnd = stat.lastIndexOf(")");
        if (nameEnd < 0)
            return "";
        const fields = stat.slice(nameEnd + 1).trim().split(" ");
        return fields.length > 1 ? fields[1] : "";
    }

    function launchedByRunner(parentPid: string, runnerPid: string): bool {
        return parentPid !== "" && parentPid === runnerPid;
    }

    Component.onCompleted: {
        Quickshell.watchFiles = !disableHotReload;
        if (!shellAllowed) {
            console.error(`VGS: refusing to start a duplicate shell: parent pid ${parentPid || "unreadable from /proc/self/stat"}, VGS_RUNNER_PID ${runnerPid || "unset"}`);
            console.error("VGS: run scripts/qml-smoke.sh for QML validation, or set VSHELL_DISABLE_INSTANCE_GUARD=1 to override.");
        }
    }

    // A binding that runs before this declaration still reads the whole file: blockAllReads loads on first read.
    FileView {
        id: ownStat
        path: "/proc/self/stat"
        blockAllReads: true
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
        running: !entrypoint.shellAllowed
        onTriggered: Quickshell.execDetached(["sh", "-c", `kill -TERM ${Quickshell.processId}`])
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
