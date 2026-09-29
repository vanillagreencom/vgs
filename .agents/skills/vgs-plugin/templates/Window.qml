import QtQuick
import qs.Commons
import qs.Ui

// __NAME__ window: an application window the core's window host builds as a
// Hyprland toplevel titled with the manifest's name. Hyprland draws its
// border, gives it the keyboard when it is focused, and moves, floats,
// tiles and closes it like any other window; the plugin never creates a
// window and draws no frame of its own. The implicit size is the first size
// the window asks for; the content fills whatever size Hyprland gives it
// after. A close through Hyprland reaches close() like a hide.
FocusScope {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    property var payload: ({})

    function open(payloadJson) {
        payload = payloadJson ? JSON.parse(payloadJson) : {};
    }

    function close() {}

    implicitWidth: Theme.size.window.width
    implicitHeight: Theme.size.panel.maxHeight
    focus: true

    Label {
        anchors.centerIn: parent
        role: "body"
        text: "__NAME__"
    }
}
