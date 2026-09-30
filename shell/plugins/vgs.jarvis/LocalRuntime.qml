import QtQuick
import Quickshell
import Quickshell.Io

// One readiness reader. Every completed setup run triggers a fresh disk check.
Item {
    id: root
    property var shell: null
    property bool pending: false
    property int code: -1
    property string output: ""
    readonly property var tuiState: shell === null ? null : shell.tui.state["setup-local"]
    readonly property var endedAt: tuiState === null || tuiState === undefined ? null : tuiState.endedAt
    readonly property string program: String(Qt.resolvedUrl("setup-local")).replace(/^file:\/\//, "")
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
        let value = { tone: "warning", text: "Setup check failed", action: true };
        try {
            if (code === 0) value = JSON.parse(output);
        } catch (error) {
            value = { tone: "warning", text: "Setup check returned invalid status", action: true };
        }
        const reply = shell.status.set("localRuntime", value);
        if (reply !== "ok") {
            const fallback = shell.status.set("localRuntime",
                { tone: "warning", text: "Setup check returned invalid status", action: true });
            if (fallback !== "ok") throw new Error("jarvis-setup: status=refused");
        }
    }
    Process {
        id: probe
        command: ["python3", "-I", root.program, "status"]
        clearEnvironment: true
        environment: ({
            PATH: Quickshell.env("PATH"), HOME: Quickshell.env("HOME"),
            XDG_STATE_HOME: Quickshell.env("XDG_STATE_HOME"),
            XDG_DATA_HOME: Quickshell.env("XDG_DATA_HOME"), LC_ALL: "C.UTF-8"
        })
        stdout: StdioCollector { onStreamFinished: root.output = text }
        stderr: StdioCollector {}
        onExited: (code, status) => root.code = status === 0 ? code : -1
        onRunningChanged: {
            if (running) return;
            root.publish();
            if (root.pending) Qt.callLater(root.refresh);
        }
    }
}
