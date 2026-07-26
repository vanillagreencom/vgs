pragma Singleton

import QtQuick

QtObject {
    // Inert compatibility surface for unsupported Mango-derived branches.
    readonly property bool available: false
    readonly property var layouts: []
    readonly property string currentKeyboardLayout: ""
    readonly property string activeOutput: ""
    readonly property var windows: []
    readonly property var allWorkspaces: []


    function getOutputState(name) { return null }
    function setLayout(name, index) {}
    function validate() {}
    function generateOutputsConfig(outputsData, settings, cb) { if (cb) cb(false) }
    function applyOutputConfig(liveName, config, cb) { if (cb) cb(false) }
    function buildOutputsConfig(outputs, settings) { return "" }
}
