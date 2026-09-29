import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// Owns the exit-record side of the `tui` capability: the FolderListModel
// listing, the per-file readers, the reaper, one `bin/vgsh-tui wait`
// process per live run, the accepted records and runs, and the `done`
// callbacks with their delivery. The listing is the fast path. The wait is
// the guarantee when FolderListModel drops a directory change. A wait can
// outlive its need: once the listing shows the run ended, a later run of
// the key may remove the run's records before the wait reads them, and the
// wait then ends `gone`, which PluginLogic.tuiWaitOutcome logs only for a
// run still awaited. No timer runs, and no wait process starts while no run
// is live.
Scope {
    id: root

    // The directory bin/vgsh-tui writes records in.
    property string recordDir: ""
    // The core's bin/ directory, where vgsh-tui lives.
    property string coreBin: ""
    // Each listed record file's path -> the record PluginLogic accepted.
    property var fileRecords: ({})
    // The ended records accepted from `vgsh-tui wait` that
    // PluginLogic.tuiWaitRecordsKept still keeps beside the listing: bounded
    // by the listed running records plus one per key.
    property var waitRecords: []
    // Each listed record file's path -> the FileView that reads it once.
    property var readers: ({})
    // PluginLogic.tuiRuns of the file and wait records.
    property var runs: Logic.tuiRuns([])
    // Each `done` waiting for its run: { id, run, done }.
    property var waiters: []
    // Each live wait id, key|run -> the Process that waits on the lock.
    property var waits: ({})
    // Wait ids whose process already finished while a running record still
    // lists the run. It is pruned to the wanted wait set, so it is bounded by
    // live running records.
    property var settled: ({})
    // Runs whose launcher exited 0 before an ended record was known. They are
    // pruned as soon as the wait finishes or the run ends, so they are bounded
    // by launches still awaiting a completion signal.
    property var launchedRuns: []

    readonly property bool recordsWatched: String(recordFiles.folder) === "file://" + recordDir

    Component.onCompleted: reap()

    onRecordsWatchedChanged: {
        if (recordsWatched) syncReaders();
        else console.error("tui: records=unwatched dir=" + recordDir + " folder=" + recordFiles.folder);
    }

    function launched(key, run) {
        launchedRuns = launchedRuns.concat([{ key: key, run: run }]);
        reconcileWaits();
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
        const listed = Object.keys(fileRecords).map(path => fileRecords[path]);
        waitRecords = Logic.tuiWaitRecordsKept(listed, waitRecords);
        runs = Logic.tuiRuns(listed.concat(waitRecords));
        reconcileWaits();
        for (const run of waiters.map(w => w.run)) deliverKnown(run);
    }

    function reconcileWaits() {
        const wanted = Logic.tuiWaitRuns(runs, launchedRuns);
        const live = {};
        for (const row of wanted) live[waitId(row.key, row.run)] = true;
        launchedRuns = launchedRuns.filter(row => Object.prototype.hasOwnProperty.call(live, waitId(row.key, row.run)));
        const nextSettled = {};
        for (const id of Object.keys(settled)) {
            if (Object.prototype.hasOwnProperty.call(live, id)) nextSettled[id] = true;
        }
        settled = nextSettled;
        for (const row of wanted) startWait(row.key, row.run);
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
        const id = waitId(process.key, process.run);
        const wanted = Logic.tuiWaitRuns(runs, launchedRuns);
        const outcome = Logic.tuiWaitOutcome(process.key, process.run, wanted, process.completion, stdout, stderr);
        for (const line of outcome.logs) console.error(line);
        const nextWaits = Object.assign({}, waits);
        delete nextWaits[id];
        waits = nextWaits;
        launchedRuns = launchedRuns.filter(row => waitId(row.key, row.run) !== id);
        const nextSettled = Object.assign({}, settled);
        nextSettled[id] = true;
        settled = nextSettled;
        if (outcome.record !== null) {
            waitRecords = waitRecords.filter(record => record.run !== outcome.record.run).concat([outcome.record]);
            refresh();
        } else {
            reconcileWaits();
        }
        process.destroy();
    }

    // One reader per listed file, kept while the file is listed. A record
    // is never rewritten, so each file is read once, however often the
    // listing's rows are rebuilt; a file read again could be removed between
    // FileView's check and its open, which it logs whatever printErrors says.
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
            waits: Object.keys(waits).sort(),
            launched: launchedRuns.map(row => row.key)
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
                // A record removed between the listing and the read.
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
