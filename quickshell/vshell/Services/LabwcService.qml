pragma Singleton

import QtQuick

QtObject {
    // Inert compatibility surface for unsupported Labwc branches.
    readonly property bool available: false
    readonly property string activeOutput: ""
    readonly property var windows: []
    readonly property var workspaces: []


    function focusWindow(id) {}
    function switchToWorkspace(id) {}
}
