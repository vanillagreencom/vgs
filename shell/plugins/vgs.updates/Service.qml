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
    // Whether the cache read has answered, loaded or failed: until then no
    // timer is set, so a service rebuilt with a fresh cache does not check
    // before it reads it.
    property bool cacheRead: false
    property bool checking: false
    property bool queued: false
    // The TUI state this instance last read, null before the first read.
    property var lastTuiState: null
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
    // Only a run that ends after this instance first read the state starts
    // a check: `shell` arrives with every run an earlier instance saw end,
    // and this handler can run before onShellChanged does, so the first read
    // is recorded and judged by nothing (UpdatesLogic.tuiRunEnded). It reads
    // the state from its source, since the binding may not have followed a
    // new `shell` yet (docs/architecture/runtime-qml.md).
    onCurrentTuiStateChanged: {
        if (shell === null) return;
        const state = shell.tui.state;
        if (Logic.tuiRunEnded(lastTuiState, state)) requestCheck("tui");
        lastTuiState = state;
    }

    function start() {
        if (shell === null || registered) return;
        registered = true;
        shell.shortcut.register("toggle", "Open or close Updates", () => root.togglePanel());
        shell.ipc.handle("check", () => root.requestCheck("ipc"));
        shell.ipc.handle("status", () => JSON.stringify(shell.status.values));
        cacheReader.path = statusPath;
        if (lastTuiState === null) lastTuiState = shell.tui.state;
        publishNow();
    }

    function togglePanel() {
        const reply = shell.surfaces.toggle("panel", "{}");
        if (reply !== "ok") console.warn("updates: panel " + reply);
        return reply;
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
        const delay = Logic.nextTimerDelay(snapshot, checking, Date.now(), currentIntervalMs, failedAt < 0 ? null : failedAt, cacheRead);
        if (delay === null) {
            cadence.stop();
            return;
        }
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

    // Reads the cache once, when start() sets its path; without `preload` it
    // would never read (docs/architecture/runtime-qml.md).
    FileView {
        id: cacheReader
        printErrors: false
        onLoaded: {
            root.cacheRead = true;
            root.acceptText(text());
            root.maybeCheck();
        }
        onLoadFailed: error => {
            root.cacheRead = true;
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
