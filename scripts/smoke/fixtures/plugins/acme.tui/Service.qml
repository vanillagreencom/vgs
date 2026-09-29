import QtQuick
// The tui capability's consumer for scripts/smoke/rows/tui.sh. Each IPC
// function hands its argument to one member and answers what it returned:
// `run` takes `<name>|<arg>|<arg>...`, a name alone passing no argument
// list, since qs ipc reads a bracketed argument as a list; `open` takes a
// key, and `entries` answers the published list as JSON.
Item {
    id: root
    property var shell: null
    property bool registered: false

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.ipc.handle("run", arg => { const parts = arg.split("|"); return root.shell.tui.run(parts[0], parts.length > 1 ? parts.slice(1) : undefined); });
        shell.ipc.handle("open", key => root.shell.tui.open(key));
        shell.ipc.handle("entries", () => JSON.stringify(root.shell.tui.entries));
    }
}
