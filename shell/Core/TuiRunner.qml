import QtQuick
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// Owns the `tui` capability's provider, the list of floating TUIs it
// publishes and every launcher it starts. PluginLogic decides which TUI a
// request names, whether its plugin is enabled, the arguments and the
// launcher's argv; this file starts one `bin/vgsh-tui launch` per accepted
// request and reads its exit. The launcher forks the terminal into a session
// of its own and exits, so a terminal outlives the shell that opened it.
// A request answers `ok` once its launcher starts; how the launcher ended
// is logged with PluginLogic.tuiLaunchOutcome, `launcher-missing` included.
Scope {
    id: root

    // Launchers still running, each a Process carrying its TUI's `key`.
    // Replaced whole on every change.
    property var launching: []

    // Every listed TUI: the core's and every enabled plugin's, as
    // PluginLogic.tuiEntries returns them.
    readonly property var entries: Logic.tuiEntries(Registry.manifests, enabledIds(), Logic.CORE_TUIS)

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
        return start(Logic.tuiRun(ctx.manifest, Registry.isEnabled(ctx.id), Registry.sourceDir, name, args));
    }

    // open: any listed TUI by key, with no arguments; the `openTui` IPC
    // function answers with this.
    function open(key) {
        return start(Logic.tuiOpen(Registry.manifests, enabledIds(), Registry.sourceDir, Logic.CORE_TUIS, key));
    }

    function start(launch) {
        if (!launch.ok) return launch.answer;
        const process = launcher.createObject(root);
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
        launching = launching.filter(p => p !== process);
        process.destroy();
    }

    // The launchers running, for the lending record.
    function record() {
        return { launching: launching.map(p => p.key) };
    }

    // A command that fails to start emits only runningChanged, so the end
    // is read there: no exit recorded is a failed start (runtime-qml.md).
    Component {
        id: launcher
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
