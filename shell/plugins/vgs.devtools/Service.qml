import QtQuick
import Quickshell
import "ViewLogic.js" as ViewLogic

// The Dev Tools service: the one owner of every command the plugin runs in
// the background, and the one writer of its status. It runs the engine's
// list, the core's doctor report, its self-status and the mise updates
// count through one Query each, publishes what they answer as plugin
// status (ViewLogic.statusValues), and keeps the launchers the
// writeLaunchers setting asks for. ViewLogic decides which queries each
// trigger runs:
//   the first shell            everything
//   vgsh ipc call vgs.devtools invoke open
//                              summons the window, then everything, a
//                              network query only when its answer is stale
//   vgsh ipc call vgs.devtools invoke refresh
//                              everything
//   a run of one of the plugin's TUIs ending (shell.tui.state), whichever
//   instance started it       the launchers, the list, the requirements and
//                              the updates
//   writeLaunchers changing    the launchers and the list
//   the core's scan finding another set of missing commands for the core
//   or an enabled plugin (shell.doctor.missing)
//                              the requirements
// The window reads the published `catalog` and runs nothing itself.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation, and
    // again when the plugin's settings change.
    property var shell: null
    // The shell this service registered with, so a settings change that
    // hands over a new object registers nothing twice.
    property var registeredWith: null
    // The VGS tree the shell runs from, which the engine and the core's
    // commands take, and this plugin's own directory in its snapshot.
    readonly property string tree: Quickshell.shellDir + "/.."
    readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
    // The writeLaunchers setting and the plugin's TUI state as bindings,
    // for their change handlers. A handler of `shell` reads the new object
    // itself: these bindings may not have followed it yet when that handler
    // runs (docs/architecture/runtime-qml.md).
    readonly property bool writeLaunchers: shell !== null && shell.settings.writeLaunchers === true
    readonly property var tuiState: shell === null ? null : shell.tui.state
    readonly property var ownerMissing: shell === null ? null : shell.doctor.missing
    // ViewLogic.missingKey of the last `missing` this service saw.
    property string seenMissing: ""
    // The writeLaunchers value the last launcher verb ran for, null before
    // the first.
    property var launchersFor: null
    // Each of the plugin's TUIs' last `endedAt` this service saw, null
    // before the first reading.
    property var seenEnds: null
    // Each query's last answer, { value, error }, by name.
    property var answers: ({})
    // When each query's last answer arrived, by name, in ms since the epoch.
    property var ended: ({})

    onShellChanged: {
        if (shell === null || registeredWith !== null) return;
        registeredWith = shell;
        shell.ipc.handle("open", () => root.open());
        shell.ipc.handle("refresh", () => { root.trigger("refresh"); return "ok"; });
        seenEnds = ViewLogic.endings(shell.tui.state);
        seenMissing = ViewLogic.missingKey(shell.doctor.missing);
        trigger("start");
    }

    onWriteLaunchersChanged: {
        if (registeredWith === null || launchersFor === wantsLaunchers()) return;
        trigger("setting");
    }

    onTuiStateChanged: {
        if (registeredWith === null) return;
        const state = shell.tui.state;
        const finished = ViewLogic.endedSince(seenEnds, state);
        seenEnds = ViewLogic.endings(state);
        if (finished.length > 0) trigger("tui");
    }

    onOwnerMissingChanged: {
        if (registeredWith === null) return;
        const key = ViewLogic.missingKey(shell.doctor.missing);
        if (key === seenMissing) return;
        seenMissing = key;
        trigger("scan");
    }

    // Summon the window, which Hyprland maps on the focused monitor, then
    // refresh; answers the window host's reply.
    function open() {
        const reply = shell.surfaces.summon("window", "{}");
        if (reply !== "ok") console.warn("devtools: summon " + reply);
        trigger("open");
        return reply;
    }

    function trigger(name) {
        for (const query of ViewLogic.queriesFor(name, ended, Date.now())) start(query);
    }

    function start(name) {
        const query = queries[name];
        const write = wantsLaunchers();
        if (name === "launchers") launchersFor = write;
        query.command = ViewLogic.queryArgv(name, tree, pluginDir, write);
        query.run();
    }

    function wantsLaunchers() {
        return shell.settings.writeLaunchers === true;
    }

    function answered(name, code, stdout, stderr) {
        const answer = ViewLogic.readAnswer(name, code, stdout, stderr);
        if (answer.error !== null) console.warn("devtools: query=" + name + " " + answer.error);
        const nextName = ViewLogic.next(name);
        if (nextName !== "") start(nextName);
        if (name === "launchers") return;
        answers = Object.assign({}, answers, { [name]: answer });
        ended = Object.assign({}, ended, { [name]: Date.now() });
        publish();
    }

    function publish() {
        const values = ViewLogic.statusValues(answers);
        for (const key of Object.keys(values)) {
            const reply = shell.status.set(key, values[key]);
            if (reply !== "ok") console.warn("devtools: status " + reply);
        }
    }

    readonly property var queries: ({ launchers: launchersQuery, catalog: catalogQuery, requirements: requirementsQuery, vgs: vgsQuery, updates: updatesQuery })

    Query { id: launchersQuery; onFinished: (code, stdout, stderr) => root.answered("launchers", code, stdout, stderr) }
    Query { id: catalogQuery; onFinished: (code, stdout, stderr) => root.answered("catalog", code, stdout, stderr) }
    Query { id: requirementsQuery; onFinished: (code, stdout, stderr) => root.answered("requirements", code, stdout, stderr) }
    Query { id: vgsQuery; onFinished: (code, stdout, stderr) => root.answered("vgs", code, stdout, stderr) }
    Query { id: updatesQuery; onFinished: (code, stdout, stderr) => root.answered("updates", code, stdout, stderr) }
}
