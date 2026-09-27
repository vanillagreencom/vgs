import QtQuick
import qs.Ui
Item {
    id: root
    property var shell: null
    property int opened: 0
    implicitWidth: 240
    implicitHeight: 120
    readonly property bool selectOpen: select.listOpen
    readonly property int selected: select.currentIndex
    function open(payloadJson) { opened += 1; }
    function close() {}
    function openSelect() { select.openList(); return "ok"; }
    function geometry() { const p = mapToGlobal(0, 0); return JSON.stringify([p.x, p.y, width, height]); }
    function selectListGeometry() { return select.listGeometry(); }
    Surface { anchors.fill: parent }
    Select {
        id: select
        x: 20; y: 20; width: 120
        model: ["alpha", "beta", "gamma"]
    }
}
