import QtQuick

QtObject {
    id: process

    property var command: []
    property bool running: false
    property var stdout: null
    property var stderr: null

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
