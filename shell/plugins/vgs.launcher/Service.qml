import QtQuick

// The launcher's service: the global shortcut and the IPC functions that
// open it. It draws nothing and owns nothing else; each registration's
// disposer is the core's, so disabling the plugin releases them.
//   shortcut vgs.launcher:toggle            SUPER+SPACE from the manifest's
//                                            `hyprland` binds (README)
//   vgsh ipc call vgs.launcher invoke toggle '<payload>'
//   vgsh ipc call vgs.launcher invoke summon '<payload>'
// A payload is the overlay's (README); an empty argument is `{}`.
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
        shell.shortcut.register("toggle", "Open or close the launcher", () => root.route("toggle", ""));
        shell.ipc.handle("toggle", arg => root.route("toggle", arg));
        shell.ipc.handle("summon", arg => root.route("summon", arg));
    }

    // The overlay's own reply: `ok`, or the host's refusal.
    function route(verb, payload) {
        const reply = shell.surfaces[verb]("overlay", payload || "{}");
        if (reply !== "ok") console.warn("launcher: " + verb + " " + reply);
        return reply;
    }
}
