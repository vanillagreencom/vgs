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
    // What the theme capability's callbacks last received, as JSON, and
    // how many times each ran.
    property string themeListed: ""
    property int themeLists: 0
    property string themeApplied: ""
    property int themeApplies: 0
    property string themeStepped: ""
    property int themeSteps: 0
    // What each of the theme capability's catalog, install, wallpapers,
    // images and set callbacks last received, by verb, and how many times
    // it ran: verb -> { count, result }.
    property var themeAnswers: ({})
    readonly property bool lockSecure: shell !== null && shell.lock.secure
    readonly property bool hasAgent: shell !== null && shell.polkit.agent !== null
    readonly property bool agentRegistered: shell !== null && shell.polkit.registered
    readonly property int screenCount: shell === null ? -1 : shell.screens.all.length
    readonly property bool noCurrentScreen: shell !== null && shell.screens.current === null

    Component { id: lockContent; Item { property var screen: null } }

    // The callback that keeps what VERB's member handed it in themeAnswers.
    function themeAnswer(verb) {
        return result => {
            const next = Object.assign({}, root.themeAnswers);
            next[verb] = { count: (verb in root.themeAnswers ? root.themeAnswers[verb].count : 0) + 1, result: result };
            root.themeAnswers = next;
        };
    }

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.shortcut.register("ping", "smoke probe", () => root.presses += 1);
        try { shell.shortcut.register("ping", "again", () => {}); } catch (e) { root.duplicateShortcut = e.message; }
        shell.ipc.handle("echo", arg => arg);
        try { shell.ipc.handle("echo", arg => arg); } catch (e) { root.duplicateIpc = e.message; }
        shell.ipc.handle("set", arg => { const at = arg.indexOf("="); return root.shell.configure.set(arg.slice(0, at), JSON.parse(arg.slice(at + 1))); });
        shell.ipc.handle("touch", path => root.shell.run.detached(["touch", path]));
        // The environment a detached process starts with, written to PATH.
        shell.ipc.handle("environ", path => root.shell.run.detached(["sh", "-c", "env >\"$1\"", "sh", path]));
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
        // theme-list, theme-apply <name> and theme-background <step> keep
        // what their callbacks received; theme <member> answers one member
        // as JSON, and theme swatch=<name> one package's swatch.
        shell.ipc.handle("theme-list", () => { root.shell.theme.list(result => { root.themeListed = JSON.stringify(result); root.themeLists += 1; }); return "ok"; });
        shell.ipc.handle("theme-apply", name => root.shell.theme.apply(name, result => { root.themeApplied = JSON.stringify(result); root.themeApplies += 1; }));
        shell.ipc.handle("theme-background", step => root.shell.theme.background(step, result => { root.themeStepped = JSON.stringify(result); root.themeSteps += 1; }));
        shell.ipc.handle("theme", member => JSON.stringify(member.startsWith("swatch=") ? root.shell.theme.swatch(member.slice(7)) : root.shell.theme[member]));
        // theme-catalog, theme-install <name>, theme-wallpapers <name>,
        // theme-images <scope> and theme-set <path>[|<screen>] keep what
        // their callbacks received in themeAnswers and answer what the
        // member returned, `ok` for catalog.
        shell.ipc.handle("theme-catalog", () => { root.shell.theme.catalog(root.themeAnswer("catalog")); return "ok"; });
        shell.ipc.handle("theme-install", name => root.shell.theme.install(name, root.themeAnswer("install")));
        shell.ipc.handle("theme-wallpapers", name => root.shell.theme.wallpapers(name, root.themeAnswer("wallpapers")));
        shell.ipc.handle("theme-images", scope => root.shell.theme.images(scope, root.themeAnswer("images")));
        shell.ipc.handle("theme-set", arg => {
            const at = arg.indexOf("|");
            return at === -1 ? root.shell.theme.set(arg, null, root.themeAnswer("set")) : root.shell.theme.set(arg.slice(0, at), arg.slice(at + 1), root.themeAnswer("set"));
        });
        // A lock holder rebuilt into a locked session hands its screen over again.
        if (shell.lock.locked) shell.lock.lock(lockContent);
    }
}
