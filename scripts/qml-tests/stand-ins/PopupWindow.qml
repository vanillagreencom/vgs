import QtQuick
import QtQuick.Window

// Stands in for Quickshell's PopupWindow under the unit tests: a plain
// window with the anchor members the overlays set and read, typed so a
// grouped assignment such as `anchor.margins.top` resolves. It positions
// nothing; the nested sandbox proves placement.
Window {
    id: window

    component Margins: QtObject {
        property int top: 0
        property int right: 0
        property int bottom: 0
        property int left: 0
    }
    component Box: QtObject {
        property real x: 0
        property real y: 0
        property real width: 0
        property real height: 0
    }
    component Anchor: QtObject {
        property Item item: null
        property int edges: 0
        property int gravity: 0
        property int adjustment: 0
        property int updates: 0
        readonly property Margins margins: Margins {}
        readonly property Box rect: Box {}
        function updateAnchor() { updates += 1; }
    }

    property bool grabFocus: false
    property int implicitWidth: 0
    property int implicitHeight: 0
    readonly property Anchor anchor: Anchor {}

    width: Math.max(1, implicitWidth)
    height: Math.max(1, implicitHeight)
    flags: Qt.Tool | Qt.FramelessWindowHint
}
