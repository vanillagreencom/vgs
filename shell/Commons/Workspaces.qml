pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland

// The compositor's workspace ids, derived once for every screen and every
// plugin that shows them, sorted, named workspaces (negative ids) left out.
Singleton {
    readonly property var ids: {
        const out = [];
        for (const ws of Hyprland.workspaces.values)
            if (ws.id > 0) out.push(ws.id);
        out.sort((a, b) => a - b);
        return out;
    }
    readonly property int focusedId: Hyprland.focusedWorkspace !== null ? Hyprland.focusedWorkspace.id : -1
}
