import QtQuick

// Reads the `hyprland` capability back for rows/hyprland-options.sh: its
// member names, the paths reported overridden, the foreign keys and the
// keymaps the keyboards are on; `switch` sends a layout switch.
Item {
    id: root
    property var shell: null
    property bool registered: false
    readonly property string members: shell === null ? "" : Object.keys(shell.hyprland).sort().join(",")
    readonly property var overridden: shell === null ? [] : shell.hyprland.overridden
    readonly property var foreignBinds: shell === null ? [] : shell.hyprland.foreignBinds
    // Each keymap a keyboard is on, once, sorted; null before the first read.
    readonly property var keymaps: {
        const devices = shell === null ? null : shell.hyprland.devices;
        if (devices === null) return null;
        return devices.keyboards.map(keyboard => keyboard.activeKeymap).filter((keymap, i, all) => all.indexOf(keymap) === i).sort();
    }

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.shortcut.register("ping", "Ping", () => {});
        shell.ipc.handle("switch", target => root.shell.hyprland.switchKeyboardLayout(/^[0-9]+$/.test(target) ? Number(target) : target));
    }
}
