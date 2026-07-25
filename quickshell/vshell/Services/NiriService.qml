pragma Singleton

import QtQuick

QtObject {
    // Hyprland-only VGS: inert compatibility surface for shared VGS-derived widgets.
    readonly property bool available: false
    readonly property string currentOutput: ""
    readonly property bool inOverview: false
    readonly property bool hasCasts: false
    readonly property bool hasActiveCast: false
    readonly property bool layoutXrayEnabled: false
    readonly property bool layoutBarXrayEnabled: false
    property bool matugenSuppression: false
    readonly property var windows: []
    readonly property var allWorkspaces: []
    readonly property var keyboardLayoutNames: []


    function suppressNextToast() { matugenSuppression = true }
    function doScreenTransition() {}
    function toggleOverview() {}
    function renameWorkspace(name) {}
    function validate() {}
    function moveColumnRight(output) {}
    function moveColumnLeft(output) {}
    function getCurrentOutputWorkspaces() { return [] }
    function getCurrentWorkspaceNumber() { return 1 }
    function switchToWorkspace(id) {}
    function moveWorkspaceToIndex(id, idx) {}
    function focusWindow(id) {}
    function getCurrentKeyboardLayoutName() { return keyboardLayoutNames[0] || "" }
    function cycleKeyboardLayout() {}
    function setLayoutXray(enabled) {}
    function setLayoutBarXray(enabled) {}
    function generateOutputsConfig(outputsData, niriSettings, cb) { if (cb) cb(false) }
    function applyOutputConfig(liveName, config, cb) { if (cb) cb(false) }
    function buildOutputsConfig(outputs, settings) { return "" }
}
