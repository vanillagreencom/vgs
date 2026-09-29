import QtQuick
import "BrowserLogic.js" as BrowserLogic

// The themes service: one global shortcut per browser view, from the view
// table in BrowserLogic.js, each summoning the plugin's overlay on that
// view. It draws nothing and owns nothing else; each registration's
// disposer is the core's, so disabling the plugin releases them.
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

    onShellChanged: {
        if (shell === null || registeredWith !== null) return;
        registeredWith = shell;
        for (const view of BrowserLogic.VIEWS)
            shell.shortcut.register(view.name, view.description, () => root.summon(view.name));
    }

    // The overlay host's reply: `ok`, or its refusal.
    function summon(view) {
        const reply = shell.surfaces.summon("overlay", JSON.stringify({ view: view }));
        if (reply !== "ok") console.warn("themes: summon " + view + " " + reply);
        return reply;
    }
}
