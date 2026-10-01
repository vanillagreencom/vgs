import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "PluginLogic.js" as Logic

// Owns the `tui` capability's provider, the list of floating TUIs it
// publishes, the launcher state and every launch process it starts: one
// `bin/vgsh-tui launch` per accepted request and at most one
// `bin/vgsh-tui check` probe. TuiRecords owns the record listing, reaper and
// one `bin/vgsh-tui wait` process per live run. PluginLogic decides which
// TUI a request names, whether its plugin is enabled, the arguments, whether
// the key is busy or the launcher state refuses it, the launcher's argv, how
// each exit moves the state, what the records say, which waits run and what
// each `done` receives. The launcher forks the terminal into a session of its
// own and exits once the presenter wrote its record, so a terminal outlives
// the shell that opened it. Each run's `done` belongs to the lifetime of the
// instance that asked: a destroyed instance's callback is dropped and its
// run still ends. The core's own request, through openCore, holds its `done`
// for the shell's life.
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
    property int launches: 0

    // The directory bin/vgsh-tui writes the records in. `bin/vgsh run`
    // creates it before the shell starts: FolderListModel lists the working
    // directory for a folder that is absent (runtime-qml-folders.md).
    readonly property string recordDir: Quickshell.env("XDG_RUNTIME_DIR") + "/vgs/tui"
    // The core's bin/ beside the shell directory, where a core TUI's command
    // lives: the shell's PATH need not hold it.
    readonly property string coreBin: Quickshell.shellDir + "/../bin"

    // Every listed TUI: the core's and every enabled plugin's, as
    // PluginLogic.tuiEntries returns them.
    readonly property var entries: Logic.tuiEntries(Registry.manifests, enabledIds(), Logic.CORE_TUIS)

    Component.onCompleted: {
        probe();
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

    // runFor: plugin ID's own declared script NAME, with no arguments and no
    // `done`, for the `manager` capability's act on a status action (D061):
    // judged as the plugin's own run, so a disabled plugin's or an
    // undeclared script is refused. Answers `ok` when the request starts
    // the TUI or focuses its live window, as PluginLogic.tuiShownAnswer
    // decides. The plugin reads the run's end from its `state`.
    function runFor(id, name) {
        const answer = start(Logic.tuiRun(Registry.manifests[id], Registry.isEnabled(id), Registry.sourceDir, runner(), name, []), null, undefined);
        return Logic.tuiShownAnswer(name, answer);
    }

    // open: any listed TUI by key, with no arguments; the `openTui` IPC
    // function answers `ok` when the request starts the TUI or focuses its
    // live window.
    function open(key) {
        const answer = start(Logic.tuiOpen(Registry.manifests, enabledIds(), Registry.sourceDir, coreBin, runner(), Logic.CORE_TUIS, key), null, undefined);
        return Logic.tuiShownAnswer(key, answer);
    }

    // openCore: the core's own TUI NAME, listed or not, with ARGS after its
    // argv, for a core component such as the requirement notice. `done`
    // receives { code, reason } as run's does, and belongs to the shell's
    // lifetime, since the core has no instance to drop it with.
    function openCore(name, args, done) {
        return start(Logic.tuiCore(Logic.CORE_TUIS, coreBin, runner(), name, args), null, done);
    }

    // The state a request is judged against, with the id a launch gets:
    // the time and a count, unique across the shell's restarts.
    function runner() {
        launches += 1;
        return {
            launcher: launcher,
            busy: Logic.tuiBusyKeys(recordStore.runs, pending.map(p => p.key)),
            run: Date.now() + "-" + launches
        };
    }

    // The calling plugin's own TUIs' state, one frozen copy per read.
    function stateOf(ctx) {
        return frozen(Logic.tuiState(recordStore.runs, ctx.id, Object.keys(ctx.manifest.tui)));
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
        process.command = [root.coreBin + "/vgsh-tui"].concat(launch.argv);
        if (done !== undefined) wait(ctx, launch.run, done);
        pending = pending.concat([{ key: launch.key, run: launch.run }]);
        launching = launching.concat([process]);
        process.running = true;
        return "ok";
    }

    // A `done` waiting for RUN, dropped with the lifetime of CTX, the
    // instance that asked, or kept for the shell's life when CTX is null,
    // the core's own request.
    function wait(ctx, run, done) {
        let release = () => {};
        const waiter = recordStore.addWaiter(ctx === null ? "core" : ctx.id, run, result => {
            release();
            done(result);
        });
        if (ctx !== null) {
            release = ctx.onDispose(() => recordStore.releaseWaiter(waiter));
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
            recordStore.deliver(process.run, failed);
        } else {
            recordStore.launched(process.key, process.run);
        }
        process.destroy();
    }

    // Brings the window of KEY's live run into view. A key busy only because its
    // launcher still waits has no window yet. A live run with no window is
    // looked for among the dead once: a presenter killed outright leaves a
    // running record that only `vgsh-tui reap` ends.
    function focus(key) {
        const slot = Object.prototype.hasOwnProperty.call(recordStore.runs.keys, key) ? recordStore.runs.keys[key] : null;
        if (slot === null || slot.running === null) return;
        const found = Logic.tuiWindow(windows(), slot.running.window);
        switch (found.state) {
        case "found":
            Compositor.reveal([found.address], false);
            break;
        case "none":
            console.warn("tui: focus=none tui=" + key);
            recordStore.reap();
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

    // A launch whose run has a record is no longer pending. It reads the
    // record owner's runs, not a binding on them: this handler runs from
    // their change signal, before such a binding need have followed it.
    function recordsChanged() {
        pending = pending.filter(p => !Object.prototype.hasOwnProperty.call(recordStore.runs.runs, p.run));
    }

    // One probe at a time: a request refused while one runs starts none.
    function probe() {
        if (prober.running) return;
        prober.completion = null;
        prober.running = true;
    }

    function frozen(value) {
        if (value === null || typeof value !== "object") return value;
        for (const key of Object.keys(value)) frozen(value[key]);
        return Object.freeze(value);
    }

    // The launchers running, the launcher state, the runs and the waiting
    // callbacks, for the lending record.
    function record() {
        const recordState = recordStore.record();
        return {
            launching: launching.map(p => p.key),
            pending: pending.map(p => p.key),
            launcher: launcher,
            probing: prober.running,
            reaping: recordState.reaping,
            runs: recordState.runs,
            waiters: recordState.waiters,
            waits: recordState.waits
        };
    }

    TuiRecords {
        id: recordStore
        recordDir: root.recordDir
        coreBin: root.coreBin
        onRunsChanged: root.recordsChanged()
    }

    // A command that fails to start emits only runningChanged, so the end
    // is read there: no exit recorded is a failed start (runtime-qml.md).
    Process {
        id: prober
        property var completion: null
        command: [root.coreBin + "/vgsh-tui", "check"]
        stderr: StdioCollector { id: probeErrors }
        onExited: (code, status) => { prober.completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const line = Logic.tuiProbeOutcome(prober.completion, probeErrors.text);
            if (line !== "") console.error(line);
            root.launcher = Logic.tuiLauncherAfter(root.launcher, prober.completion);
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
