import QtQuick
import Quickshell
import Quickshell.Io
import "UpdatesLogic.js" as Logic

// Owns vgs.updates runtime state: cached snapshot readback, one check
// process, cadence timers, IPC and every status write. Widgets and panels
// read status only; this service is the single writer.
Item {
    id: root

    property var shell: null
    property bool registered: false
    property var snapshot: null
    property bool checking: false
    property bool queued: false
    property var lastTuiState: ({})
    property string checkFailure: ""
    property double failedAt: -1
    property var reported: ({})
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/vgs/updates"
    readonly property string statusPath: stateDir + "/status.json"
    readonly property string checkScript: String(Qt.resolvedUrl("bin/check")).replace(/^file:\/\//, "")
    readonly property string vgshPath: Quickshell.shellDir + "/../bin/vgsh"
    readonly property int currentIntervalMs: Logic.intervalMs(shell === null ? null : shell.settings)
    readonly property var currentTuiState: shell === null || shell.tui === undefined ? ({}) : shell.tui.state

    onShellChanged: start()
    onCurrentIntervalMsChanged: schedule()
    onCurrentTuiStateChanged: {
        if (shell === null || shell.tui === undefined) return;
        if (Logic.tuiRunEnded(lastTuiState, currentTuiState)) requestCheck("tui");
        lastTuiState = currentTuiState;
    }

    function start() {
        if (shell === null || registered) return;
        registered = true;
        shell.ipc.handle("check", () => root.requestCheck("ipc"));
        shell.ipc.handle("status", () => JSON.stringify(shell.status.values));
        cacheReader.path = statusPath;
        cacheReader.reload();
        lastTuiState = currentTuiState;
        publishNow();
    }

    function requestCheck(reason) {
        if (checking) {
            queued = true;
            return "queued";
        }
        checking = true;
        checkProc.command = [checkScript, "--vgsh", vgshPath];
        checkProc.running = true;
        publishNow();
        return "started";
    }

    function maybeCheck() {
        if (Logic.shouldRunCheck(snapshot, checking, Date.now(), currentIntervalMs, failedAt < 0 ? null : failedAt)) requestCheck("due");
        else schedule();
    }

    function schedule() {
        const delay = Logic.nextTimerDelay(snapshot, checking, Date.now(), currentIntervalMs, failedAt < 0 ? null : failedAt);
        cadence.interval = Math.max(1000, Math.min(delay, 2147483647));
        cadence.restart();
    }

    function acceptText(text) {
        const judged = Logic.parseSnapshotText(text);
        if (!judged.ok) {
            console.warn("updates: cache refused: " + judged.error);
            return false;
        }
        snapshot = judged.snapshot;
        checkFailure = "";
        failedAt = -1;
        publishNow();
        schedule();
        return true;
    }

    function publishNow() {
        if (shell === null) return;
        const values = Logic.publishValues(snapshot, checking, Date.now(), currentIntervalMs, checkFailure);
        const writes = Logic.statusWrites(reported, values);
        if (writes.length === 0) return;
        const next = Object.assign({}, reported);
        for (const write of writes) {
            const reply = shell.status.set(write.key, write.value);
            if (reply !== "ok") console.error("updates: " + reply);
            else next[write.key] = write.value;
        }
        reported = next;
    }

    FileView {
        id: cacheReader
        preload: false
        printErrors: false
        onLoaded: {
            root.acceptText(text());
            root.maybeCheck();
        }
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound) console.warn("updates: cache unreadable: " + error);
            root.publishNow();
            root.maybeCheck();
        }
    }

    Process {
        id: checkProc
        stdout: StdioCollector { id: checkOut }
        stderr: StdioCollector { id: checkErr }
        property var completion: null
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            root.checking = false;
            if (done !== null && done.code === 0 && root.acceptText(checkOut.text)) {
                root.checkFailure = "";
                root.failedAt = -1;
            } else {
                const line = String(checkErr.text || "").split("\n").filter(l => l !== "")[0] || "no-output";
                root.checkFailure = (done === null ? "start=failed" : "exit=" + done.code) + " " + line;
                root.failedAt = Date.now();
                root.publishNow();
                root.schedule();
            }
            if (root.queued) {
                root.queued = false;
                root.requestCheck("queued");
            }
        }
    }

    Timer {
        id: cadence
        repeat: false
        interval: root.currentIntervalMs
        onTriggered: {
            if (Logic.shouldRunCheck(root.snapshot, root.checking, Date.now(), root.currentIntervalMs, root.failedAt < 0 ? null : root.failedAt)) root.requestCheck("timer");
            else {
                root.publishNow();
                root.schedule();
            }
        }
    }
}
