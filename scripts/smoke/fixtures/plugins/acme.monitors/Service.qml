import QtQuick

// Reads the `monitors` capability back for rows/monitor-rules.sh and
// rows/monitor-preview.sh: its member names, the outputs, the saved rules,
// the identifiers overridden, a write's progress and a preview's; `write`
// hands the capability the `rules` of a JSON object and answers its reply,
// `preview` the `rules` and `seconds` of one, and `confirm` and `revert` a
// token. Its one bind gives the layer a plugin section, so the row reads
// the Monitors section's place whatever the rows before it left enabled.
// The rules ride in an object because `qs ipc call` strips the brackets of
// an argument that starts with `[`.
Item {
    id: root
    property var shell: null
    property bool registered: false
    readonly property string members: shell === null ? "" : Object.keys(shell.monitors).sort().join(",")
    readonly property var outputs: shell === null ? null : shell.monitors.outputs
    readonly property var saved: shell === null ? null : shell.monitors.saved
    readonly property var overridden: shell === null ? null : shell.monitors.overridden
    readonly property var writeState: shell === null ? null : shell.monitors.writeState
    readonly property var previewState: shell === null ? null : shell.monitors.previewState

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.shortcut.register("ping", "Ping", () => {});
        shell.ipc.handle("write", text => {
            let request;
            try {
                request = JSON.parse(text);
            } catch (e) {
                return "refused: rules=unparsed";
            }
            return root.shell.monitors.write(request.rules);
        });
        shell.ipc.handle("preview", text => {
            let request;
            try {
                request = JSON.parse(text);
            } catch (e) {
                return "refused: rules=unparsed";
            }
            return root.shell.monitors.preview(request.rules, request.seconds);
        });
        shell.ipc.handle("confirm", token => root.shell.monitors.confirm(token));
        shell.ipc.handle("revert", token => root.shell.monitors.revert(token));
    }
}
