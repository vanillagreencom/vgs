import QtQuick

Item {
    id: root
    property var shell: null
    readonly property bool locked: shell !== null && shell.session.locked
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
    property int changes: 0
    property bool registered: false
    onLockedChanged: changes += 1

    function readOnly() {
        const session = shell.session;
        const before = session.locked;
        const mutations = [
            () => { session.locked = !before; },
            () => Object.defineProperty(session, "locked", { value: !before }),
            () => { delete session.locked; },
            () => { session.unlock = () => "planted"; }
        ];
        for (const change of mutations) {
            try { change(); } catch (e) {}
        }
        return Object.isFrozen(session) && Object.keys(session).join(",") === "locked"
            && session.locked === before && session.lock === undefined && session.unlock === undefined;
    }

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.ipc.handle("read-only", () => root.readOnly());
    }
}
