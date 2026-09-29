import QtQuick
// The tui capability's consumer for scripts/smoke/rows/tui.sh. Each IPC
// function hands its argument to one member and answers what it returned:
// `run` takes `<name>|<arg>|<arg>...`, a name alone passing no argument
// list, since qs ipc reads a bracketed argument as a list; `runDone` takes
// the same and passes a `done` that keeps each result this instance
// received, which `dones` answers as JSON [name, code, reason] rows;
// `open` takes a key; `entries` and `state` answer the published list and
// this plugin's run state as JSON.
Item {
    id: root
    property var shell: null
    property bool registered: false
    property var dones: []

    function request(arg, done) {
        const parts = arg.split("|");
        const args = parts.length > 1 ? parts.slice(1) : undefined;
        return done === undefined ? root.shell.tui.run(parts[0], args) : root.shell.tui.run(parts[0], args, done);
    }

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.ipc.handle("run", arg => root.request(arg, undefined));
        shell.ipc.handle("runDone", arg => {
            const name = arg.split("|")[0];
            return root.request(arg, result => { root.dones = root.dones.concat([[name, result.code, result.reason]]); });
        });
        shell.ipc.handle("dones", () => JSON.stringify(root.dones));
        shell.ipc.handle("open", key => root.shell.tui.open(key));
        shell.ipc.handle("entries", () => JSON.stringify(root.shell.tui.entries));
        shell.ipc.handle("state", () => JSON.stringify(root.shell.tui.state));
    }
}
