import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import "AutomationsLogic.js" as Logic

// Owns vgs.automations' runtime side: it syncs the units with the store
// when it starts, so they run the revision the shell runs, lists the
// automations whenever a run file comes or goes and when the next run is
// due, prunes the history with the plugin's historyDays setting at start,
// on a change and once a day, and writes every status value. Every
// question goes to bin/automations, one call at a time, since the engine
// owns the store, the units and the records.
//
//   vgsh ipc call vgs.automations invoke <name> ""   with <name>:
//     status    the published values, JSON
//     sync      sync, then list; `ok`
//     refresh   list; `ok`
//     linger    opens the linger TUI; shell.tui.run's reply
Item {
    id: root

    property var shell: null
    property bool registered: false
    // The engine calls waiting to run, each an argv after `--tree <dir>`.
    property var queue: []
    property var reported: ({})
    // `list --json`'s last document, null before the first.
    property var listed: null
    property string problem: ""
    readonly property string engine: String(Qt.resolvedUrl("bin/automations")).replace(/^file:\/\//, "")
    readonly property string tree: Quickshell.shellDir + "/.."
    readonly property int historyDays: shell === null ? Logic.HISTORY_DAYS_MAX : shell.settings.historyDays
    readonly property string runsFolder: listed === null ? "" : "file://" + listed.runsDir

    onShellChanged: start()
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
        shell.ipc.handle("linger", () => shell.tui.run("linger", [], () => root.request(["list", "--json"])));
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

    function finished(args, done, stdoutText, stderrText) {
        if (done === null || done.code !== 0) {
            const line = String(stderrText || "").split("\n").filter(l => l !== "")[0] || "no-output";
            problem = (args[0] + " " + (done === null ? "start=failed" : "exit=" + done.code) + " " + line).slice(0, 200);
            console.warn("automations: " + problem);
            publish();
            return;
        }
        if (args[0] !== "list") return;
        let doc;
        try {
            doc = JSON.parse(stdoutText);
        } catch (e) {
            problem = "list answer=not-json";
            console.warn("automations: " + problem);
            publish();
            return;
        }
        listed = doc;
        problem = "";
        publish();
        refresh.interval = Logic.refreshDelay(doc, Date.now());
        refresh.restart();
    }

    function publish() {
        if (shell === null || listed === null && problem === "") return;
        const values = listed === null ? {} : Logic.statusValues(listed);
        values.problem = problem === "" ? { tone: "ok", text: "None" } : { tone: "danger", text: problem };
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
        onCountChanged: if (root.runsFolder !== "" && String(folder) === root.runsFolder) settle.restart()
    }

    Timer {
        id: settle
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
