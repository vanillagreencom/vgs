import QtQuick
import Quickshell.Io

// One read-only command the service runs: `command` is its argv, and each
// run ends in `finished(code, stdout, stderr)`, `code` null when the
// command did not start. A run asked for while one runs starts once it
// ends, so a burst of requests runs the command twice at most and the last
// answer follows the last request. The command's output is kept whole
// until the run ends: every command here prints one JSON line or a few
// lines of text.
Item {
    id: query

    property var command: []
    // A run asked for while one runs.
    property bool again: false
    readonly property bool running: process.running

    signal finished(var code, string stdout, string stderr)

    function run() {
        if (process.running) {
            again = true;
            return;
        }
        process.command = command;
        process.running = true;
    }

    Process {
        id: process

        // The exit of the run, { code }, null until `exited` arrives: a
        // command that fails to start emits `runningChanged` alone
        // (docs/architecture/runtime-qml.md).
        property var completion: null

        stdout: StdioCollector { id: out }
        stderr: StdioCollector { id: err }
        onExited: (code, status) => { completion = { code: code }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            query.finished(done === null ? null : done.code, out.text, err.text);
            if (!query.again) return;
            query.again = false;
            query.run();
        }
    }
}
