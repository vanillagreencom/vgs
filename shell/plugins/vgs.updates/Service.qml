import QtQuick
import Quickshell
import Quickshell.Io
import "UpdatesLogic.js" as Logic

Item {
    id: root

    property var shell: null
    property bool registered: false
    property var snapshot: null
    property bool checking: false
    property bool queued: false
    property var lastTuiState: ({})
    property string checkError: ""
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/vgs/updates"
    readonly property string statusPath: stateDir + "/status.json"
    readonly property string checkScript: String(Qt.resolvedUrl("bin/check")).replace(/^file:\/\//, "")
    readonly property int currentIntervalMs: Logic.intervalMs(shell === null ? null : shell.settings)
    readonly property var published: Logic.publishValues(snapshot, checking, Date.now(), currentIntervalMs)

    onShellChanged: start()
    onCurrentIntervalMsChanged: schedule()
    onPublishedChanged: publish()

    function start() {
        if (shell === null || registered) return;
        registered = true;
        shell.ipc.handle("check", () => root.requestCheck("ipc"));
        shell.ipc.handle("status", () => JSON.stringify(root.published));
        cacheReader.path = statusPath;
        cacheReader.reload();
        lastTuiState = shell.tui === undefined ? ({}) : shell.tui.state;
        tuiWatch.start();
    }

    function requestCheck(reason) {
        if (checking) {
            queued = true;
            return "queued";
        }
        checkError = "";
        checking = true;
        checkProc.command = [checkScript];
        checkProc.environment = { VGS_UPDATES_VGSH: Quickshell.shellDir + "/../bin/vgsh" };
        checkProc.running = true;
        publish();
        return "started";
    }

    function maybeCheck() {
        const delay = Logic.nextCheckDelay(snapshot, checking, Date.now(), currentIntervalMs);
        if (delay === 0) requestCheck("due");
        else schedule();
    }

    function schedule() {
        const delay = Logic.nextCheckDelay(snapshot, checking, Date.now(), currentIntervalMs);
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
        schedule();
        publish();
        return true;
    }

    function publish() {
        if (shell === null) return;
        const values = Logic.publishValues(snapshot, checking, Date.now(), currentIntervalMs);
        setStatus("pending", values.pending);
        if (values.lastCheck !== null) setStatus("lastCheck", values.lastCheck);
        setStatus("checkState", values.checkState);
        setStatus("sources", values.sources);
    }

    function setStatus(key, value) {
        const reply = shell.status.set(key, value);
        if (reply !== "ok") console.error("updates: " + reply);
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
            root.publish();
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
                root.checkError = "";
            } else {
                const line = String(checkErr.text || "").split("\n").filter(l => l !== "")[0] || "no-output";
                root.checkError = (done === null ? "start=failed" : "exit=" + done.code) + " " + line;
                root.snapshot = { checkedAt: Date.now(), sources: [], error: root.checkError };
                root.publish();
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
        onTriggered: root.requestCheck("timer")
    }

    Timer {
        id: tuiWatch
        interval: 1000
        repeat: true
        onTriggered: {
            if (root.shell === null || root.shell.tui === undefined) return;
            const next = root.shell.tui.state;
            if (Logic.tuiRunEnded(root.lastTuiState, next)) root.requestCheck("tui");
            root.lastTuiState = next;
        }
    }
}
