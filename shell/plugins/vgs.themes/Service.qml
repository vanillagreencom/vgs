import QtQuick
import Quickshell
import Quickshell.Io
import "BrowserLogic.js" as BrowserLogic
import "SetupLogic.js" as SetupLogic

// The themes service: one global shortcut per browser view, from the view
// table in BrowserLogic.js, each summoning the plugin's overlay on that
// view, and the Browser theming status row. It draws nothing; each
// registration's disposer is the core's, so disabling the plugin releases
// them. The row asks `vgsh theme setup --json` at start and after each run
// of the `browser-policy` TUI, whoever opened it, the one step that changes
// its answer from the shell, and publishes SetupLogic.browserTheming's
// answer; the Settings page offers Install browser theming, that TUI,
// while it says so (D061). A browser installed while the shell runs is
// read at its next start.
//   shortcut vgs.themes:themes              SUPER+T from the manifest's
//                                            `hyprland` binds (README)
//   shortcut vgs.themes:wallpapers          SUPER+W, the same way
// A shortcut summons rather than toggles: the overlay's `open` closes it
// when it already shows that view and switches to the view otherwise, so a
// second view's key moves an open browser to it instead of closing it.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    // The shell this service registered with, so a settings change that
    // hands over a new object registers nothing twice.
    property var registeredWith: null

    // The end of the browser-policy TUI's last run: each new end asks the
    // setup report again.
    readonly property var policyEnd: shell === null || !shell.tui.state["browser-policy"] ? null : shell.tui.state["browser-policy"].endedAt

    onShellChanged: {
        if (shell === null || registeredWith !== null) return;
        registeredWith = shell;
        for (const view of BrowserLogic.VIEWS)
            shell.shortcut.register(view.name, view.description, () => root.summon(view.name));
        checkSetup();
    }
    onPolicyEndChanged: if (registeredWith !== null) checkSetup()

    // Ask `vgsh theme setup --json` again; one asked while it runs runs
    // once it ends.
    property bool setupPending: false
    function checkSetup() {
        if (setupReport.running) { setupPending = true; return; }
        setupReport.running = true;
    }

    Process {
        id: setupReport
        command: [Quickshell.shellDir + "/../bin/vgsh", "theme", "setup", "--json"]
        stdout: StdioCollector { id: setupOut }
        property var exitCode: null
        onExited: code => { exitCode = code; }
        onRunningChanged: {
            if (running) return;
            const value = SetupLogic.browserTheming(setupOut.text, exitCode === null ? -1 : exitCode);
            exitCode = null;
            if (value.tone === "danger") console.warn("themes: setup=unknown " + value.text);
            if (root.shell !== null) {
                const reply = root.shell.status.set("browserTheming", value);
                if (reply !== "ok") console.error("themes: " + reply);
            }
            if (root.setupPending) {
                root.setupPending = false;
                running = true;
            }
        }
    }

    // The overlay host's reply: `ok`, or its refusal.
    function summon(view) {
        const reply = shell.surfaces.summon("overlay", JSON.stringify({ view: view }));
        if (reply !== "ok") console.warn("themes: summon " + view + " " + reply);
        return reply;
    }
}
