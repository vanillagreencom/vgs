import QtQuick
import qs.Commons
import qs.Ui as Ui

// __NAME__ pane: one section mounted inside the enabled holder of the
// exclusive `panes` capability. The core assigns this plugin's scoped
// shell object after creation. The pane fills the holder's container and
// keeps every setup, setting and secret inside this plugin's own API.
FocusScope {
    id: root

    property var shell: null
    property var payload: ({})
    readonly property Item initialFocus: content

    function open(payloadJson) {
        payload = payloadJson ? JSON.parse(payloadJson) : {};
    }

    function close() {}

    implicitWidth: Theme.size.panel.lg
    implicitHeight: content.implicitHeight
    focus: true

    Ui.Pane {
        id: content
        anchors.fill: parent
        header: Ui.Label {
            role: "h2"
            text: "__NAME__"
        }

        Ui.Label {
            role: "body"
            text: "Pane content"
        }
    }
}
