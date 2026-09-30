import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// One presence reader, refreshed after the core reports an add-key TUI end.
Item {
    id: root
    property var shell: null
    property bool pending: false
    property int code: -1
    property string output: ""
    readonly property var tuiState: shell === null ? null : shell.tui.state["add-key"]
    readonly property var endedAt: tuiState === null || tuiState === undefined ? null : tuiState.endedAt
    readonly property string program: String(Qt.resolvedUrl("backend/keys.js")).replace(/^file:\/\//, "")
    onShellChanged: refresh()
    onEndedAtChanged: if (endedAt !== null) refresh()

    function refresh() {
        if (shell === null) return;
        if (probe.running) { pending = true; return; }
        pending = false;
        code = -1;
        output = "";
        probe.running = true;
    }
    function publish() {
        let rows;
        try {
            if (code !== 0) throw new Error("probe");
            rows = JSON.parse(output);
        } catch (error) {
            rows = [{ label: "Key references", value: "unavailable", hint: "jarvis-keys: presence=failed" }];
        }
        let answer = shell.status.set("keys", rows);
        if (answer !== "ok") {
            answer = shell.status.set("keys", [{ label: "Key references", value: "unavailable",
                hint: "jarvis-keys: presence=invalid" }]);
            if (answer !== "ok") throw new Error("jarvis-keys: status=refused");
        }
    }
    Process {
        id: probe
        command: ["node", root.program, "presence"]
        clearEnvironment: true
        environment: ({
            PATH: Quickshell.env("PATH"), HOME: Quickshell.env("HOME"),
            XDG_CONFIG_HOME: Quickshell.env("XDG_CONFIG_HOME"), XDG_STATE_HOME: Quickshell.env("XDG_STATE_HOME"),
            XDG_DATA_HOME: Quickshell.env("XDG_DATA_HOME"), XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
            DBUS_SESSION_BUS_ADDRESS: Quickshell.env("DBUS_SESSION_BUS_ADDRESS"), LANG: "C.UTF-8"
        })
        stdout: StdioCollector { onStreamFinished: root.output = text }
        // Never forward helper stderr. The keyed status owns this diagnosis.
        stderr: StdioCollector {}
        onExited: (code, status) => root.code = status === 0 ? code : -1
        onRunningChanged: {
            if (running) return;
            root.publish();
            if (root.pending) Qt.callLater(root.refresh);
        }
    }
}
