import QtQuick

Item {
    id: root
    property var shell: null
    property bool registered: false
    property var edges: []
    readonly property string keys: shell === null ? "" : JSON.stringify(shell.shortcut.keys)

    function edge(value) {
        edges = edges.concat([value]);
        console.log("hold-fixture: edge=" + value);
    }

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.shortcut.register("talk", "hold talk", () => root.edge("talk-down"), () => root.edge("talk-up"));
        const releaseOther = shell.shortcut.register("other", "hold other", () => root.edge("other-down"), () => root.edge("other-up"));
        shell.ipc.handle("reset", () => { root.edges = []; return "ok"; });
        shell.ipc.handle("release-other", () => { releaseOther(); return "ok"; });
    }
}
