import QtQuick
Item {
    id: root
    property var shell: null
    readonly property string label: shell === null ? "" : String(shell.settings.label)
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
    property bool registered: false
    property int presses: 0
    property string duplicateShortcut: ""
    property string duplicateIpc: ""
    property int notified: 0
    property string lastSummary: ""
    // title -> disposer of a toast this service showed.
    property var toasts: ({})
    property string lastToastRefusal: ""
    readonly property bool lockSecure: shell !== null && shell.lock.secure
    readonly property bool hasAgent: shell !== null && shell.polkit.agent !== null
    readonly property bool agentRegistered: shell !== null && shell.polkit.registered
    readonly property int screenCount: shell === null ? -1 : shell.screens.all.length
    readonly property bool noCurrentScreen: shell !== null && shell.screens.current === null

    Component { id: lockContent; Item { property var screen: null } }

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.shortcut.register("ping", "smoke probe", () => root.presses += 1);
        try { shell.shortcut.register("ping", "again", () => {}); } catch (e) { root.duplicateShortcut = e.message; }
        shell.ipc.handle("echo", arg => arg);
        try { shell.ipc.handle("echo", arg => arg); } catch (e) { root.duplicateIpc = e.message; }
        shell.ipc.handle("set", arg => { const at = arg.indexOf("="); return root.shell.configure.set(arg.slice(0, at), JSON.parse(arg.slice(at + 1))); });
        shell.ipc.handle("touch", path => root.shell.run.detached(["touch", path]));
        shell.ipc.handle("lock", () => root.shell.lock.lock(lockContent));
        shell.ipc.handle("unlock", () => root.shell.lock.unlock());
        shell.ipc.handle("dispatch", arg => { const a = arg.split(" "); return root.shell.compositor[a[0]].apply(null, a.slice(1)); });
        // Several dispatches in one call, separated by ";", so they reach
        // the queue back to back; answers every reply joined by ",".
        shell.ipc.handle("batch", arg => arg.split(";").map(one => { const a = one.split(" "); return root.shell.compositor[a[0]].apply(null, a.slice(1)); }).join(","));
        // N dispatches of one request in one call; answers the last reply.
        shell.ipc.handle("flood", arg => { const a = arg.split(" "); let last = ""; for (let i = 0; i < Number(a[0]); i++) last = root.shell.compositor[a[1]].apply(null, a.slice(2)); return last; });
        shell.notifications.subscribe(n => { root.notified += 1; root.lastSummary = n.summary; });
        // toast <title>[|<tone>[|<duration>]] shows one; a refusal is kept
        // and answered. untoast <title> runs its disposer.
        shell.ipc.handle("toast", arg => {
            const parts = arg.split("|");
            const options = { title: parts[0] };
            if (parts[1] !== undefined && parts[1] !== "") options.tone = parts[1];
            if (parts[2] !== undefined) options.duration = Number(parts[2]);
            try {
                root.toasts[parts[0]] = root.shell.toasts.show(options);
                return "ok";
            } catch (e) {
                root.lastToastRefusal = e.message;
                return e.message;
            }
        });
        shell.ipc.handle("untoast", title => { const release = root.toasts[title]; if (release === undefined) return "absent"; release(); delete root.toasts[title]; return "ok"; });
        // A lock holder rebuilt into a locked session hands its screen over again.
        if (shell.lock.locked) shell.lock.lock(lockContent);
    }
}
