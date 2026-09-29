import QtQuick
import Qt.labs.folderlistmodel
import Quickshell.Io
import "PluginLogic.js" as Logic

Item {
    id: root

    property string recordDir: ""
    property string coreBin: ""
    property var fileRecords: ({})
    property var waitRecords: ({})
    property var readers: ({})
    property var runs: Logic.tuiRuns([])
    property var waiters: []
    property var waits: ({})
    property var settled: ({})

    readonly property bool recordsWatched: String(recordFiles.folder) === "file://" + recordDir

    Component.onCompleted: reap()

    onRecordsWatchedChanged: {
        if (recordsWatched) syncReaders();
        else console.error("tui: records=unwatched dir=" + recordDir + " folder=" + recordFiles.folder);
    }

    function launched(key, run) {
        startWait(key, run);
    }

    function addWaiter(id, run, done) {
        const waiter = { id: id, run: run, done: done };
        waiters = waiters.concat([waiter]);
        return waiter;
    }

    function releaseWaiter(waiter) {
        waiters = waiters.filter(w => w !== waiter);
    }

    function deliverKnown(run) {
        const result = Logic.tuiRunDone(runs, run);
        if (result !== null) deliver(run, result);
    }

    function deliver(run, result) {
        const due = waiters.filter(w => w.run === run);
        if (due.length === 0) return;
        waiters = waiters.filter(w => w.run !== run);
        const shared = frozen(result);
        for (const waiter of due) {
            try {
                waiter.done(shared);
            } catch (e) {
                console.error("capabilities: tui done of " + waiter.id + " threw: " + e.message);
            }
        }
    }

    function recordLoaded(path, text) {
        const judged = Logic.tuiRecord(text);
        if (!judged.ok) {
            console.error("tui: record=" + path + " refused: " + judged.error);
            return;
        }
        const next = Object.assign({}, fileRecords);
        next[path] = judged.record;
        fileRecords = next;
        refresh();
    }

    function recordGone(path) {
        if (!Object.prototype.hasOwnProperty.call(fileRecords, path)) return;
        const next = Object.assign({}, fileRecords);
        delete next[path];
        fileRecords = next;
        refresh();
    }

    function refresh() {
        runs = Logic.tuiRuns(Object.keys(fileRecords).map(path => fileRecords[path]).concat(Object.keys(waitRecords).map(key => waitRecords[key])));
        pruneSettled();
        ensureRunningWaits();
        for (const run of waiters.map(w => w.run)) deliverKnown(run);
    }

    function ensureRunningWaits() {
        for (const row of Logic.tuiWaitRuns(runs, [])) startWait(row.key, row.run);
    }

    function waitId(key, run) {
        return key + "|" + run;
    }

    function startWait(key, run) {
        const id = waitId(key, run);
        if (Object.prototype.hasOwnProperty.call(waits, id) || Object.prototype.hasOwnProperty.call(settled, id))
            return;
        const process = waitComponent.createObject(root);
        process.key = key;
        process.run = run;
        process.command = [coreBin + "/vgsh-tui", "wait", "--record", key, "--run", run];
        const next = Object.assign({}, waits);
        next[id] = process;
        waits = next;
        process.running = true;
    }

    function finishWait(process, stdout, stderr) {
        const outcome = Logic.tuiWaitOutcome(process.key, process.run, process.completion, stdout, stderr);
        for (const line of outcome.logs) console.error(line);
        const nextWaits = Object.assign({}, waits);
        delete nextWaits[waitId(process.key, process.run)];
        waits = nextWaits;
        const nextSettled = Object.assign({}, settled);
        nextSettled[waitId(process.key, process.run)] = true;
        settled = nextSettled;
        if (outcome.record !== null) {
            const nextRecords = Object.assign({}, waitRecords);
            nextRecords[outcome.record.key] = outcome.record;
            waitRecords = nextRecords;
            refresh();
        } else {
            pruneSettled();
        }
        process.destroy();
    }

    function pruneSettled() {
        const live = {};
        for (const row of Logic.tuiWaitRuns(runs, [])) live[waitId(row.key, row.run)] = true;
        const next = {};
        for (const id of Object.keys(settled)) {
            if (Object.prototype.hasOwnProperty.call(live, id)) next[id] = true;
        }
        settled = next;
    }

    function syncReaders() {
        const listed = {};
        for (let i = 0; i < recordFiles.count; i++) listed[recordFiles.get(i, "filePath")] = true;
        const next = {};
        for (const path of Object.keys(readers)) {
            if (Object.prototype.hasOwnProperty.call(listed, path)) {
                next[path] = readers[path];
                continue;
            }
            readers[path].destroy();
            recordGone(path);
        }
        for (const path of Object.keys(listed)) {
            if (Object.prototype.hasOwnProperty.call(next, path)) continue;
            const reader = readerComponent.createObject(root);
            reader.path = path;
            next[path] = reader;
        }
        readers = next;
    }

    function reap() {
        if (reaper.running) return;
        reaper.completion = null;
        reaper.running = true;
    }

    function record() {
        const keys = {};
        for (const key of Object.keys(runs.keys)) {
            const slot = runs.keys[key];
            keys[key] = {
                running: slot.running === null ? null : slot.running.run,
                ended: slot.ended === null ? null : { run: slot.ended.run, code: slot.ended.code }
            };
        }
        return {
            reaping: reaper.running,
            runs: keys,
            waiters: waiters.map(w => w.id),
            waits: Object.keys(waits).sort()
        };
    }

    function frozen(value) {
        if (value === null || typeof value !== "object") return value;
        for (const key of Object.keys(value)) frozen(value[key]);
        return Object.freeze(value);
    }

    FolderListModel {
        id: recordFiles
        folder: "file://" + root.recordDir
        nameFilters: ["*.json"]
        showDirs: false
        showDotAndDotDot: false
        showHidden: false
    }

    Connections {
        target: recordFiles
        enabled: root.recordsWatched
        function onModelReset() { root.syncReaders(); }
        function onRowsInserted() { root.syncReaders(); }
        function onRowsRemoved() { root.syncReaders(); }
    }

    Component {
        id: readerComponent
        FileView {
            id: reader
            printErrors: false
            onLoaded: root.recordLoaded(reader.path, text())
            onLoadFailed: error => {
                if (error !== FileViewError.FileNotFound) console.error("tui: record=" + reader.path + " unreadable: error=" + error);
            }
        }
    }

    Process {
        id: reaper
        property var completion: null
        command: [root.coreBin + "/vgsh-tui", "reap"]
        stdout: StdioCollector { id: reaped }
        stderr: StdioCollector { id: reapErrors }
        onExited: (code, status) => { reaper.completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            for (const line of Logic.tuiReapOutcome(reaper.completion, reaped.text, reapErrors.text)) {
                switch (line.level) {
                case "info":
                    console.info(line.text);
                    break;
                case "error":
                    console.error(line.text);
                    break;
                default:
                    throw new Error("tui: reap line level " + JSON.stringify(line.level) + " is not one of info, error");
                }
            }
        }
    }

    Component {
        id: waitComponent
        Process {
            id: process
            property string key: ""
            property string run: ""
            property var completion: null
            stdout: StdioCollector { id: output }
            stderr: StdioCollector { id: errors }
            onExited: (code, status) => { process.completion = { code: code, status: status }; }
            onRunningChanged: {
                if (running) return;
                root.finishWait(process, output.text, errors.text);
            }
        }
    }
}
