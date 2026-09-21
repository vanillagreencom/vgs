import QtQuick
import qs.Commons

// __NAME__ panel: a summoned surface drawn inside the core's panel host.
// The host calls open(payloadJson) and close(); the plugin never creates
// a window. Colours and spacing come from Color and Style.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    property var payload: ({})
    property bool shown: false

    function open(payloadJson) {
        try {
            payload = payloadJson ? JSON.parse(payloadJson) : {};
        } catch (e) {
            console.error("__ID__: open payload does not parse: " + e.message);
            payload = {};
        }
        shown = true;
    }

    function close() {
        shown = false;
    }

    implicitWidth: Style.space(60)
    implicitHeight: Style.space(40)

    Rectangle {
        anchors.fill: parent
        color: Color.background
        radius: Style.cornerRadius

        Text {
            anchors.centerIn: parent
            text: "__NAME__"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.size
        }
    }
}
