import QtQuick
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// Owns the `tui` capability's provider, the list of floating TUIs it
// publishes, the launcher state and every process it starts: one
// `bin/vgsh-tui launch` per accepted request and at most one
// `bin/vgsh-tui check` probe at a time. PluginLogic decides which TUI a
// request names, whether its plugin is enabled, the arguments, whether the
// launcher state refuses it, the launcher's argv and how each exit moves the
// state. The launcher forks the terminal into a session of its own and
// exits, so a terminal outlives the shell that opened it.
Scope {
    id: root

    // Launchers still running, each a Process carrying its TUI's `key`.
    // Replaced whole on every change.
    property var launching: []
    // One of PluginLogic.TUI_LAUNCHER_STATES: the first probe answers it,
    // and every later probe and launch moves it.
    property string launcher: "unknown"

    // Every listed TUI: the core's and every enabled plugin's, as
    // PluginLogic.tuiEntries returns them.
    readonly property var entries: Logic.tuiEntries(Registry.manifests, enabledIds(), Logic.CORE_TUIS)

    Component.onCompleted: probe()

    // Every enabled plugin id, read through Registry.isEnabled so a binding
    // on the result follows the configuration and the manifests.
    function enabledIds() {
        return Object.keys(Registry.manifests).filter(id => Registry.isEnabled(id));
    }

    function provider(ctx) {
        return {
            run: (name, args) => root.run(ctx, name, args),
            get entries() { return root.entries; },
            open: key => root.open(key)
        };
    }

    // run: one of the calling plugin's own declared scripts, from the
    // snapshot of the revision its instance runs.
    function run(ctx, name, args) {
        return start(Logic.tuiRun(ctx.manifest, Registry.isEnabled(ctx.id), Registry.sourceDir, launcher, name, args));
    }

    // open: any listed TUI by key, with no arguments; the `openTui` IPC
    // function answers with this.
    function open(key) {
        return start(Logic.tuiOpen(Registry.manifests, enabledIds(), Registry.sourceDir, launcher, Logic.CORE_TUIS, key));
    }

    function start(launch) {
        if (!launch.ok) {
            if (launch.probe) probe();
            return launch.answer;
        }
        const process = launcherComponent.createObject(root);
        process.key = launch.key;
        // Assigned after creation: a list handed to createObject crosses a
        // QVariant conversion (runtime-qml.md).
        process.command = [Quickshell.shellDir + "/../bin/vgsh-tui"].concat(launch.argv);
        launching = launching.concat([process]);
        process.running = true;
        return "ok";
    }

    function finish(process, stderr) {
        const line = Logic.tuiLaunchOutcome(process.key, process.completion, stderr);
        if (line !== "") console.error(line);
        launcher = Logic.tuiLauncherAfter(launcher, process.completion);
        launching = launching.filter(p => p !== process);
        process.destroy();
    }

    // One probe at a time: a request refused while one runs starts none.
    function probe() {
        if (prober.running) return;
        prober.completion = null;
        prober.running = true;
    }

    // The launchers running and the launcher state, for the lending record.
    function record() {
        return { launching: launching.map(p => p.key), launcher: launcher, probing: prober.running };
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

    Component {
        id: launcherComponent
        Process {
            id: process
            property string key: ""
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
