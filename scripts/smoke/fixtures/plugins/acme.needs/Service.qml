import QtQuick
// The requirements capability's consumer for scripts/smoke/rows/notices.sh.
// `offer` takes `<command>|<command>...` and hands the list to
// shell.requirements.offer; `offer-json` hands it the JSON value its
// argument parses to, so a row can offer what is not a list of commands.
// Each answers what offer returned. `missing` answers
// shell.requirements.missing as one JSON line.
Item {
    id: root
    property var shell: null
    property bool registered: false

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.ipc.handle("offer", arg => root.shell.requirements.offer(arg.split("|")));
        shell.ipc.handle("offer-json", arg => root.shell.requirements.offer(JSON.parse(arg)));
        shell.ipc.handle("missing", () => JSON.stringify(root.shell.requirements.missing));
    }
}
