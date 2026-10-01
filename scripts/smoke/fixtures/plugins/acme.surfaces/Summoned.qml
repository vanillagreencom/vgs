import QtQuick
import QtQuick.Templates as T
import qs.Ui
Item {
    id: root
    property var shell: null
    property alias initialFocus: focusTarget
    property int opened: 0
    property string lastPayload: ""
    implicitWidth: 200
    implicitHeight: 120
    // A payload may name a file close() creates, and may ask open() to throw.
    function open(payloadJson) {
        const payload = JSON.parse(payloadJson);
        opened += 1;
        lastPayload = payloadJson;
        if (payload.fail === true) throw new Error("probe open refused");
    }
    function close() {
        const marker = JSON.parse(lastPayload).closeMarker;
        if (marker !== undefined) shell.run.detached(["touch", marker]);
    }
    function geometry() { const p = mapToGlobal(0, 0); return JSON.stringify([p.x, p.y, width, height]); }
    function menuHere(payload) { return shell.surfaces.summon("menu", payload || "{}", menuAnchor); }
    function moveAnchor() { container.y += 20; return "ok"; }
    function hideAnchor() { container.visible = false; return "ok"; }
    function anchorGeometry() { const p = menuAnchor.mapToGlobal(0, 0); return JSON.stringify([p.x, p.y, menuAnchor.width, menuAnchor.height]); }
    T.Control {
        id: focusTarget
        property string text: "Initial focus"
        width: 120
        height: 40
        anchors.centerIn: parent
        focusPolicy: Qt.StrongFocus
        background: Item { FocusRing { target: focusTarget } }
    }
    Item {
        id: container
        x: 40
        y: 20
        Item { id: menuAnchor; x: 20; y: 10; width: 20; height: 20 }
    }
}
