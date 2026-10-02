import QtQuick

// The System service: the global shortcut and the IPC functions that open
// the window. A window instance exists only while the window is open, so
// the shortcut, which must answer while it is closed, is registered here.
// It draws nothing and owns nothing else; each registration's disposer is
// the core's, so disabling the plugin releases them. The shortcut and the
// IPC open the window on the focused monitor.
//   shortcut vgs.system:toggle            SUPER+COMMA from the manifest's
//                                          `hyprland` binds
//   vgsh ipc call vgs.system invoke toggle '<payload>'
//   vgsh ipc call vgs.system invoke open '<payload>'
// A payload is the window's, `{}` or `{"pane":"<id>", ...}`; an empty
// argument is `{}`.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    // The shell this service registered with, so a settings change that
    // hands over a new object registers nothing twice.
    property var registeredWith: null

    onShellChanged: {
        if (shell === null || registeredWith !== null) return;
        registeredWith = shell;
        shell.shortcut.register("toggle", "Open or close System", () => root.route("toggle", ""));
        shell.ipc.handle("toggle", arg => root.route("toggle", arg));
        shell.ipc.handle("open", arg => root.route("summon", arg));
    }

    // The window host's reply: `ok`, or its refusal.
    function route(verb, payload) {
        const reply = shell.surfaces[verb]("window", payload || "{}");
        if (reply !== "ok") console.warn("system: " + verb + " " + reply);
        return reply;
    }
}
