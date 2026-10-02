import QtQuick
import qs.Commons
import qs.Ui

// __NAME__ pane: one section mounted inside the enabled holder of the
// exclusive `panes` capability. The core assigns this plugin's scoped
// shell object after creation. The holder draws the section's title and
// icon, owns the inset around it and scrolls it, so the pane is a body
// alone: no Pane, no title, its content from x 0, and its height its
// implicitHeight, which the holder sizes its container from. It keeps
// every setup, setting and secret inside this plugin's own API.
FocusScope {
    id: root

    property var shell: null
    property var payload: ({})
    readonly property Item initialFocus: content

    function open(payloadJson) {
        payload = payloadJson ? JSON.parse(payloadJson) : {};
    }

    function close() {}

    implicitWidth: Theme.size.window.width
    implicitHeight: content.implicitHeight
    focus: true

    Column {
        id: content
        width: root.width
        spacing: Theme.stack.group

        Label {
            width: parent.width
            role: "body"
            text: "Pane content"
            wrapMode: Text.Wrap
        }
    }
}
