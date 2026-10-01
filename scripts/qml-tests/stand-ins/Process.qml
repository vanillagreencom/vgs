import QtQuick

// Stands in for Quickshell.Io's Process, whose plugin does not load outside
// the shell. The TUI records test sets stdout and stderr and then emits
// exited before running becomes false, matching the runtime order the core
// relies on.
QtObject {
    id: process

    property var command: []
    property bool running: false
    property var stdout: null
    property var stderr: null
    property var environment: ({})
    property bool clearEnvironment: false
    property bool stdinEnabled: false

    signal started()
    signal exited(int code, int status)

    function finish(code, status, out, err) {
        if (stdout !== null) stdout.text = out === undefined ? "" : out;
        if (stderr !== null) stderr.text = err === undefined ? "" : err;
        exited(code, status);
        running = false;
    }

    function failStart() {
        running = false;
    }

    Component.onCompleted: ProcessRegistry.add(process)
    Component.onDestruction: ProcessRegistry.remove(process)
}
