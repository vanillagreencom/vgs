import QtQuick
import Quickshell

// The lock's service: the global shortcut and the IPC function that lock
// the session. Both run `vgsh lock` detached, so hyprlock is no child of
// the shell and a shell that stops or crashes leaves the session locked
// and unlockable. It draws nothing and owns nothing else; each
// registration's disposer is the core's, so disabling the plugin releases
// them.
//   shortcut vgs.lock:lock                 SUPER+L from the manifest's
//                                          `hyprland` binds
//   vgsh ipc call vgs.lock invoke lock ''  answers the run's reply
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    // The shell this service registered with, so a settings change that
    // hands over a new object registers nothing twice.
    property var registeredWith: null
    // The runner of the tree the shell runs from, which needs no running
    // shell: bin/vgsh-lock.
    readonly property string vgsh: Quickshell.shellDir + "/../bin/vgsh"

    onShellChanged: {
        if (shell === null || registeredWith !== null) return;
        registeredWith = shell;
        shell.shortcut.register("lock", "Lock the session", () => root.lock());
        shell.ipc.handle("lock", () => root.lock());
    }

    // `ok` once the run is handed over, or the core's refusal. A hyprlock
    // that is missing or refuses is vgsh's to report on its own stderr.
    function lock() {
        const reply = shell.run.detached([vgsh, "lock"]);
        if (reply !== "ok") console.warn("lock: " + reply);
        return reply;
    }
}
