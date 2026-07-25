pragma Singleton

import QtQuick

QtObject {
    // Hyprland-only VGS: inert compatibility surface.
    readonly property bool available: false
    readonly property string activeOutput: ""
    readonly property var windows: []
    readonly property var workspaces: []


    function focusWindow(id) {}
    function switchToWorkspace(id) {}
}
