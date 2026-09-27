import QtQuick
import qs.Commons

// __NAME__ panel: a summoned surface drawn inside the core's panel host.
// The host calls open(payloadJson) and close(); the plugin never creates
// a window. A payload that does not parse throws out of open(), and the
// host answers the summon with `refused: open-failed=<id>`. Colours and
// spacing come from Theme. To open another declared kind here,
// pass its source Item to shell.surfaces.summon(kind, payloadJson, item);
// the compositor places it relative to this window.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    property var payload: ({})

    function open(payloadJson) {
        payload = payloadJson ? JSON.parse(payloadJson) : {};
    }

    function close() {}

    implicitWidth: Theme.size.panel.sm
    implicitHeight: Theme.size.panel.sm / 2

    Rectangle {
        anchors.fill: parent
        color: Theme.color.surface
        radius: Theme.radius.md

        Text {
            anchors.centerIn: parent
            text: "__NAME__"
            color: Theme.color.text
            font.family: Theme.text.body.family
            font.pixelSize: Theme.text.body.size
        }
    }
}
