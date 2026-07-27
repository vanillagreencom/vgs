pragma Singleton

import QtQuick

QtObject {
    // VGS uses compositor-native output control instead of wlr-output-management.
    readonly property bool wlrOutputAvailable: false
    readonly property var outputs: []

    signal stateReceived()

    function getOutput(name) { return null }
    function requestState() { stateReceived() }
    function applyOutputsConfig(outputsData, outputsArg) { return false }
}
