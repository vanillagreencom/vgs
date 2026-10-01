import QtQuick
import Quickshell.Io

// Coalesces one Hyprland read. A new request made while the process runs
// replaces the pending request, and the running reply is dropped.
Item {
    id: root

    property string label: "hyprctl"
    property var currentRequest: null
    property var pendingCommand: null
    property var pendingRequest: null
    property bool again: false

    signal readDone(var request, string stdoutText, string failure)

    function read(argv, request) {
        if (proc.running) {
            pendingCommand = argv;
            pendingRequest = request;
            again = true;
            return;
        }
        currentRequest = request;
        proc.command = argv;
        proc.running = true;
    }

    function failureOf(completion, err) {
        if (completion === null) return label + "-start=failed";
        if (completion.code !== 0) return label + "=failed status=" + completion.code + (err === "" ? "" : " stderr=" + JSON.stringify(err));
        return "";
    }

    Process {
        id: proc
        property var completion: null
        stdout: StdioCollector { id: out }
        stderr: StdioCollector { id: err }
        onExited: (code, status) => { completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            const done = completion;
            completion = null;
            if (root.again) {
                const argv = root.pendingCommand;
                const request = root.pendingRequest;
                root.pendingCommand = null;
                root.pendingRequest = null;
                root.again = false;
                root.read(argv, request);
                return;
            }
            root.readDone(root.currentRequest, out.text, root.failureOf(done, err.text.trim()));
        }
    }
}
