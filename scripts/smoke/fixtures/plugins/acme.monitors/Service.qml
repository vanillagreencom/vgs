import QtQuick

// Reads the `monitors` capability back for rows/monitor-rules.sh: its
// member names, the outputs, the saved rules, the identifiers overridden
// and a write's progress; `write` hands the capability the `rules` of a
// JSON object and answers its reply. The rules ride in an object because
// `qs ipc call` strips the brackets of an argument that starts with `[`.
Item {
    id: root
    property var shell: null
    property bool registered: false
    readonly property string members: shell === null ? "" : Object.keys(shell.monitors).sort().join(",")
    readonly property var outputs: shell === null ? null : shell.monitors.outputs
    readonly property var saved: shell === null ? null : shell.monitors.saved
    readonly property var overridden: shell === null ? null : shell.monitors.overridden
    readonly property var writeState: shell === null ? null : shell.monitors.writeState

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.ipc.handle("write", text => {
            let request;
            try {
                request = JSON.parse(text);
            } catch (e) {
                return "refused: rules=unparsed";
            }
            return root.shell.monitors.write(request.rules);
        });
    }
}
