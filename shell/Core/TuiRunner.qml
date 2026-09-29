import QtQuick
import QtQml.Models
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "PluginLogic.js" as Logic

// Owns the `tui` capability's provider, the list of floating TUIs it
// publishes, the launcher state, the runs the exit records describe and
// every process it starts: one `bin/vgsh-tui launch` per accepted request,
// at most one `bin/vgsh-tui check` probe and at most one `bin/vgsh-tui
// reap` at a time. PluginLogic decides which TUI a request names, whether
// its plugin is enabled, the arguments, whether the key is busy or the
// launcher state refuses it, the launcher's argv, how each exit moves the
// state, what the records say and what each `done` receives. The launcher
// forks the terminal into a session of its own and exits once the
// presenter wrote its record, so a terminal outlives the shell that opened
// it. Each run's `done` belongs to the lifetime of the instance that asked:
// a destroyed instance's callback is dropped and its run still ends.
Scope {
    id: root

    // Launchers still running, each a Process carrying its TUI's `key` and
    // `run`. Replaced whole on every change.
    property var launching: []
    // Launches whose run has no record yet and whose launcher did not fail,
    // each { key, run }: the key stays busy until the record appears.
    property var pending: []
    // One of PluginLogic.TUI_LAUNCHER_STATES: the first probe answers it,
    // and every later probe and launch moves it.
    property string launcher: "unknown"
    // Each record file's path -> the record PluginLogic.tuiRecord accepted.
    property var records: ({})
    // PluginLogic.tuiRuns of the records, replaced whole on every change.
    property var runs: Logic.tuiRuns([])
    // Each `done` waiting for its run: { id, run, done, release }.
    property var waiters: []
    property int launches: 0

    // The directory bin/vgsh-tui writes the records in. `bin/vgsh run`
    // creates it before the shell starts: FolderListModel lists the working
    // directory for a folder that is absent (runtime-qml.md).
    readonly property string recordDir: Quickshell.env("XDG_RUNTIME_DIR") + "/vgs/tui"
    readonly property bool recordsWatched: String(recordFiles.folder) === "file://" + recordDir

    // Every listed TUI: the core's and every enabled plugin's, as
    // PluginLogic.tuiEntries returns them.
    readonly property var entries: Logic.tuiEntries(Registry.manifests, enabledIds(), Logic.CORE_TUIS)

    Component.onCompleted: {
        probe();
        reap();
    }

    onRecordsWatchedChanged: {
        if (!recordsWatched) console.error("tui: records=unwatched dir=" + recordDir + " folder=" + recordFiles.folder);
    }

    // Every enabled plugin id, read through Registry.isEnabled so a binding
    // on the result follows the configuration and the manifests.
    function enabledIds() {
        return Object.keys(Registry.manifests).filter(id => Registry.isEnabled(id));
    }

    function provider(ctx) {
        return {
            run: (name, args, done) => root.run(ctx, name, args, done),
            get entries() { return root.entries; },
            open: key => root.open(key),
            get state() { return root.stateOf(ctx); }
        };
    }

    // run: one of the calling plugin's own declared scripts, from the
    // snapshot of the revision its instance runs. `done`, when given,
    // receives { code, reason } once the run ends or its launcher fails.
    function run(ctx, name, args, done) {
        if (done !== undefined && typeof done !== "function")
            throw new Error("refused: tui=" + Logic.tuiLabel(name) + " done=not-a-function");
        return start(Logic.tuiRun(ctx.manifest, Registry.isEnabled(ctx.id), Registry.sourceDir, runner(), name, args), ctx, done);
    }

    // open: any listed TUI by key, with no arguments; the `openTui` IPC
    // function answers with this.
    function open(key) {
        return start(Logic.tuiOpen(Registry.manifests, enabledIds(), Registry.sourceDir, Quickshell.shellDir + "/../bin", runner(), Logic.CORE_TUIS, key), null, undefined);
    }

    // The state a request is judged against, with the id a launch gets:
    // the time and a count, unique across the shell's restarts.
    function runner() {
        launches += 1;
        return {
            launcher: launcher,
            busy: Logic.tuiBusyKeys(runs, pending.map(p => p.key)),
            run: Date.now() + "-" + launches
        };
    }

    // The calling plugin's own TUIs' state, one frozen copy per read.
    function stateOf(ctx) {
        return frozen(Logic.tuiState(runs, ctx.id, Object.keys(ctx.manifest.tui)));
    }

    function start(launch, ctx, done) {
        if (!launch.ok) {
            switch (launch.action) {
            case "none":
                break;
            case "probe":
                probe();
                break;
            case "focus":
                focus(launch.key);
                break;
            default:
                throw new Error("tui: refusal action " + JSON.stringify(launch.action) + " is not one of " + Logic.TUI_ACTIONS.join(", "));
            }
            return launch.answer;
        }
        const process = launcherComponent.createObject(root);
        process.key = launch.key;
        process.run = launch.run;
        // Assigned after creation: a list handed to createObject crosses a
        // QVariant conversion (runtime-qml.md).
        process.command = [Quickshell.shellDir + "/../bin/vgsh-tui"].concat(launch.argv);
        if (done !== undefined) wait(ctx, launch.run, done);
        pending = pending.concat([{ key: launch.key, run: launch.run }]);
        launching = launching.concat([process]);
        process.running = true;
        return "ok";
    }

    function wait(ctx, run, done) {
        const waiter = { id: ctx.id, run: run, done: done };
        waiter.release = ctx.onDispose(() => {
            root.waiters = root.waiters.filter(w => w !== waiter);
        });
        waiters = waiters.concat([waiter]);
    }

    // Hands RESULT to every `done` still waiting for RUN, once.
    function deliver(run, result) {
        const due = waiters.filter(w => w.run === run);
        if (due.length === 0) return;
        waiters = waiters.filter(w => w.run !== run);
        const shared = frozen(result);
        for (const waiter of due) {
            waiter.release();
            try {
                waiter.done(shared);
            } catch (e) {
                console.error("capabilities: tui done of " + waiter.id + " threw: " + e.message);
            }
        }
    }

    function finish(process, stderr) {
        const line = Logic.tuiLaunchOutcome(process.key, process.completion, stderr);
        if (line !== "") console.error(line);
        launcher = Logic.tuiLauncherAfter(launcher, process.completion);
        launching = launching.filter(p => p !== process);
        const failed = Logic.tuiLaunchDone(process.completion);
        if (failed !== null) {
            pending = pending.filter(p => p.run !== process.run);
            deliver(process.run, failed);
        }
        process.destroy();
    }

    // Focuses the window of KEY's live run. A key busy only because its
    // launcher still waits has no window yet. A live run with no window is
    // looked for among the dead once: a presenter killed outright leaves a
    // running record that only `vgsh-tui reap` ends.
    function focus(key) {
        const slot = Object.prototype.hasOwnProperty.call(runs.keys, key) ? runs.keys[key] : null;
        if (slot === null || slot.running === null) return;
        const found = Logic.tuiWindow(windows(), slot.running.window);
        switch (found.state) {
        case "found":
            Compositor.send("focusWindow", [found.address]);
            break;
        case "none":
            console.warn("tui: focus=none tui=" + key);
            reap();
            break;
        case "ambiguous":
            console.warn("tui: focus=ambiguous tui=" + key + " windows=" + found.count);
            break;
        default:
            throw new Error("tui: window state " + JSON.stringify(found.state) + " is not one of found, none, ambiguous");
        }
    }

    function windows() {
        return Hyprland.toplevels.values.map(t => ({
            address: t.address,
            appId: t.wayland ? t.wayland.appId : ((t.lastIpcObject && t.lastIpcObject.class) || ""),
            title: t.title
        }));
    }

    function recordLoaded(path, text) {
        const judged = Logic.tuiRecord(text);
        if (!judged.ok) {
            console.error("tui: record=" + path + " refused: " + judged.error);
            return;
        }
        const next = Object.assign({}, records);
        next[path] = judged.record;
        records = next;
        refresh();
    }

    function recordGone(path) {
        if (!Object.prototype.hasOwnProperty.call(records, path)) return;
        const next = Object.assign({}, records);
        delete next[path];
        records = next;
        refresh();
    }

    // The runs the records now describe: a launch whose run has a record
    // is no longer pending, and every run that ended answers its `done`.
    function refresh() {
        runs = Logic.tuiRuns(Object.keys(records).map(path => records[path]));
        pending = pending.filter(p => !Object.prototype.hasOwnProperty.call(runs.runs, p.run));
        for (const run of waiters.map(w => w.run)) {
            const result = Logic.tuiRunDone(runs, run);
            if (result !== null) deliver(run, result);
        }
    }

    // One probe at a time: a request refused while one runs starts none.
    function probe() {
        if (prober.running) return;
        prober.completion = null;
        prober.running = true;
    }

    // One reap at a time, for the same reason.
    function reap() {
        if (reaper.running) return;
        reaper.completion = null;
        reaper.running = true;
    }

    function frozen(value) {
        if (value === null || typeof value !== "object") return value;
        for (const key of Object.keys(value)) frozen(value[key]);
        return Object.freeze(value);
    }

    // The launchers running, the launcher state, the runs and the waiting
    // callbacks, for the lending record.
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
            launching: launching.map(p => p.key),
            pending: pending.map(p => p.key),
            launcher: launcher,
            probing: prober.running,
            reaping: reaper.running,
            runs: keys,
            waiters: waiters.map(w => w.id)
        };
    }

    FolderListModel {
        id: recordFiles
        folder: "file://" + root.recordDir
        nameFilters: ["*.json"]
        showDirs: false
        showDotAndDotDot: false
        showHidden: false
    }

    // One reader per record file. A record is never rewritten, so a file
    // read once is read for good; a file that leaves the listing leaves the
    // records.
    Instantiator {
        active: root.recordsWatched
        model: recordFiles
        delegate: FileView {
            required property string filePath
            path: filePath
            printErrors: false
            onLoaded: root.recordLoaded(filePath, text())
            onLoadFailed: error => {
                // A record removed between the listing and the read.
                if (error !== FileViewError.FileNotFound) console.error("tui: record=" + filePath + " unreadable: error=" + error);
            }
        }
        onObjectRemoved: (index, object) => root.recordGone(object.filePath)
    }

    // A command that fails to start emits only runningChanged, so the end
    // is read there: no exit recorded is a failed start (runtime-qml.md).
    Process {
        id: prober
        property var completion: null
        command: [Quickshell.shellDir + "/../bin/vgsh-tui", "check"]
        stderr: StdioCollector { id: probeErrors }
        onExited: (code, status) => { prober.completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const line = Logic.tuiProbeOutcome(prober.completion, probeErrors.text);
            if (line !== "") console.error(line);
            root.launcher = Logic.tuiLauncherAfter(root.launcher, prober.completion);
        }
    }

    Process {
        id: reaper
        property var completion: null
        command: [Quickshell.shellDir + "/../bin/vgsh-tui", "reap"]
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
        id: launcherComponent
        Process {
            id: process
            property string key: ""
            property string run: ""
            property var completion: null
            stderr: StdioCollector { id: errors }
            onExited: (code, status) => { process.completion = { code: code, status: status }; }
            onRunningChanged: {
                if (running) return;
                root.finish(process, errors.text);
            }
        }
    }
}
