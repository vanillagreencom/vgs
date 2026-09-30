import QtQuick
import Quickshell
import Quickshell.Io

// Serialized client for bin/automations. Service.qml and Window.qml use it
// so the plugin has one subprocess queue and one refusal shape.
Item {
    id: root

    readonly property string engine: String(Qt.resolvedUrl("bin/automations")).replace(/^file:\/\//, "")
    readonly property string tree: Quickshell.shellDir + "/.."
    property var queue: []
    property var active: null

    function request(args, done) {
        const key = JSON.stringify(args);
        if (queue.some(q => JSON.stringify(q.args) === key) || (active !== null && JSON.stringify(active.args) === key)) return;
        queue = queue.concat([{ args: args, done: done }]);
        pump();
    }

    function requestJson(args, done) {
        request(args, (ok, stdoutText, stderrText, failure) => {
            if (!ok) {
                done(false, null, failure);
                return;
            }
            try {
                done(true, JSON.parse(stdoutText), "");
            } catch (e) {
                done(false, null, args[0] + " answer=not-json");
            }
        });
    }

    function pump() {
        if (cli.running || queue.length === 0) return;
        active = queue[0];
        queue = queue.slice(1);
        cli.command = [engine, "--tree", tree].concat(active.args);
        cli.running = true;
    }

    function firstLine(text) {
        const lines = String(text || "").split("\n").filter(line => line.trim() !== "");
        return lines.length > 0 ? lines[0] : "";
    }

    function finish(done, stdoutText, stderrText) {
        const request = active;
        active = null;
        const ok = done !== null && done.code === 0;
        const failure = ok ? "" : (request.args[0] + " " + (done === null ? "start=failed" : "exit=" + done.code) + " " + firstLine(stderrText));
        if (request !== null && request.done !== undefined) request.done(ok, stdoutText, stderrText, failure);
        pump();
    }

    Process {
        id: cli
        property var completion: null
        stdout: StdioCollector { id: cliOut }
        stderr: StdioCollector { id: cliErr }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            root.finish(done, cliOut.text, cliErr.text);
        }
    }
}
