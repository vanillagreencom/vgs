import QtQuick
import qs.Commons

// __NAME__ panel: a summoned surface drawn inside the core's panel host.
// The host calls open(payloadJson) and close(); the plugin never creates
// a window. A payload that does not parse throws out of open(), and the
// host answers the summon with `refused: open-failed=<id>`. Colours and
// spacing come from Color and Style.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    property var payload: ({})

    function open(payloadJson) {
        payload = payloadJson ? JSON.parse(payloadJson) : {};
    }

    function close() {}

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
