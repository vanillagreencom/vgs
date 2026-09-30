import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.Commons
import "AutomationsLogic.js" as Logic

// Owns vgs.automations' runtime side: it syncs the units with the store
// when it starts, so they run the revision the shell runs, lists the
// automations whenever a run file comes or goes, the store changes, as the
// engine's add, edit, enable, disable and remove change it from any caller,
// and when the next run is due, prunes the history with the plugin's historyDays setting at start,
// on a change and once a day, and writes every status value. Every
// question goes to bin/automations, one call at a time, since the engine
// owns the store, the units and the records.
//
//   vgsh ipc call vgs.automations invoke <name> ""   with <name>:
//     status    the published values, JSON
//     sync      sync, then list; `ok`
//     refresh   list; `ok`
//     linger    opens the linger TUI; shell.tui.run's reply. Its end
//               lists again, as every run of it does.
Item {
    id: root

    property var shell: null
    property bool registered: false
    // The engine calls waiting to run, each an argv after `--tree <dir>`.
    property var queue: []
    property var reported: ({})
    // `list --json`'s last document, null before the first.
    property var listed: null
    // Each engine operation's last failure (AutomationsLogic.withOutcome).
    property var failures: ({})
    readonly property string engine: String(Qt.resolvedUrl("bin/automations")).replace(/^file:\/\//, "")
    readonly property string tree: Quickshell.shellDir + "/.."
    readonly property int historyDays: shell === null ? Logic.HISTORY_DAYS_MAX : shell.settings.historyDays
    readonly property string runsFolder: listed === null ? "" : "file://" + listed.runsDir
    readonly property string storeFile: listed === null ? "" : listed.storeFile

    // The end of the linger TUI's last run, whoever opened it: the
    // launcher, this plugin's IPC or the Settings page's Enable while logged
    // out action. Each new end lists again, since lingering is no file the
    // service watches.
    readonly property var lingerEnd: shell === null || !shell.tui.state.linger ? null : shell.tui.state.linger.endedAt

    onShellChanged: start()
    onLingerEndChanged: if (registered && lingerEnd !== null) request(["list", "--json"])
    onHistoryDaysChanged: if (registered) request(["prune", "--days", String(historyDays)])

    function start() {
        if (shell === null || registered) return;
        registered = true;
        shell.ipc.handle("status", () => JSON.stringify(shell.status.values));
        shell.ipc.handle("sync", () => {
            root.request(["sync"]);
            root.request(["list", "--json"]);
            return "ok";
        });
        shell.ipc.handle("refresh", () => {
            root.request(["list", "--json"]);
            return "ok";
        });
        shell.ipc.handle("linger", () => shell.tui.run("linger", []));
        request(["sync"]);
        request(["prune", "--days", String(historyDays)]);
        request(["list", "--json"]);
    }

    function request(args) {
        const key = JSON.stringify(args);
        if (queue.some(q => JSON.stringify(q) === key)) return;
        queue = queue.concat([args]);
        pump();
    }

    function pump() {
        if (cli.running || queue.length === 0) return;
        const next = queue[0];
        queue = queue.slice(1);
        cli.args = next;
        cli.command = [engine, "--tree", tree].concat(next);
        cli.running = true;
    }

    function fail(operation, line) {
        console.warn("automations: " + line);
        failures = Logic.withOutcome(failures, operation, line);
        publish();
    }

    function finished(args, done, stdoutText, stderrText) {
        const operation = args[0];
        if (done === null || done.code !== 0) {
            const line = String(stderrText || "").split("\n").filter(l => l !== "")[0] || "no-output";
            fail(operation, operation + " " + (done === null ? "start=failed" : "exit=" + done.code) + " " + line);
            return;
        }
        if (operation !== "list") {
            failures = Logic.withOutcome(failures, operation, "");
            publish();
            return;
        }
        let doc;
        try {
            doc = JSON.parse(stdoutText);
        } catch (e) {
            fail(operation, "list answer=not-json");
            return;
        }
        listed = doc;
        failures = Logic.withOutcome(failures, operation, "");
        publish();
        refresh.interval = Logic.refreshDelay(doc, Date.now());
        refresh.restart();
    }

    function publish() {
        if (shell === null) return;
        const values = listed === null ? {} : Logic.statusValues(listed);
        values.problem = Logic.engineProblem(failures);
        const next = Object.assign({}, reported);
        for (const key of Logic.changedKeys(reported, values)) {
            const reply = shell.status.set(key, values[key]);
            if (reply !== "ok") console.error("automations: " + reply);
            else next[key] = values[key];
        }
        reported = next;
    }

    Process {
        id: cli
        property var args: []
        property var completion: null
        stdout: StdioCollector { id: cliOut }
        stderr: StdioCollector { id: cliErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            root.finished(args, done, cliOut.text, cliErr.text);
            root.pump();
        }
    }

    // A run writes its started and ended records under new names, so the
    // listing's count moves with each; the list the change asks for waits a
    // moment for the records that come together. The listing can miss a
    // change under load (docs/architecture/runtime-qml.md), which the
    // refresh timer bounds.
    FolderListModel {
        id: runs
        folder: root.runsFolder
        nameFilters: ["*.json"]
        showDirs: false
        onCountChanged: if (root.runsFolder !== "" && String(folder) === root.runsFolder) listSoon.restart()
    }

    // The store is an invalidation signal only: every change, and the first
    // read, asks the engine to list, which reads and judges the store.
    // WatchedFile raises `changed` while no read is in flight, and a change
    // during a read makes the read report again, so no change is dropped.
    LazyLoader {
        active: root.storeFile !== ""
        WatchedFile {
            path: root.storeFile
            onChanged: listSoon.restart()
            onLoaded: content => listSoon.restart()
            onLoadFailed: error => listSoon.restart()
        }
    }

    Timer {
        id: listSoon
        interval: 250
        onTriggered: root.request(["list", "--json"])
    }

    Timer {
        id: refresh
        repeat: false
        onTriggered: root.request(["list", "--json"])
    }

    Timer {
        interval: Logic.DAY_MS
        repeat: true
        running: root.registered
        onTriggered: root.request(["prune", "--days", String(root.historyDays)])
    }
}
