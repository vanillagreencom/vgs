import QtQuick
// The bluetoothAgent capability's holder for
// scripts/smoke/rows/bluetooth-agent.sh. IPC: `begin` takes a lease with
// the argument as its reason and answers the lease's state at once;
// `release` releases it; `answer` takes `<id>|<JSON value>` and answers
// what the agent answered. The row reads `leaseState`, `leaseRefusal`,
// `agentReady` and `requests` back.
Item {
    id: root
    property var shell: null
    property bool registered: false
    property var lease: null
    readonly property string leaseState: lease === null ? "none" : lease.state
    readonly property string leaseRefusal: lease === null ? "" : lease.refusal
    readonly property bool agentReady: shell !== null && shell.bluetoothAgent.ready
    readonly property var requests: shell === null ? [] : shell.bluetoothAgent.requests

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.ipc.handle("begin", reason => {
            if (root.lease !== null) return "refused: lease=held";
            root.lease = root.shell.bluetoothAgent.begin(reason);
            return root.lease.state;
        });
        shell.ipc.handle("release", () => {
            if (root.lease === null) return "refused: lease=none";
            root.lease.release();
            root.lease = null;
            return "ok";
        });
        shell.ipc.handle("answer", arg => {
            const cut = arg.indexOf("|");
            return root.shell.bluetoothAgent.answer(Number(arg.slice(0, cut)), JSON.parse(arg.slice(cut + 1)));
        });
    }
}
