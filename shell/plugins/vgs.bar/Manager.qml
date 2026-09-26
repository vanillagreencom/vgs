import QtQuick
import qs.Commons
import "Reply.js" as Reply

// The plugin manager's button. A click opens the bar's own manager panel
// under the button, or closes it when it is open.
Item {
    id: root

    // The bar, read for its `shell` alone.
    required property Item bar

    implicitWidth: label.implicitWidth + Style.spacing.lg
    implicitHeight: Style.bar.sizeHorizontal

    // Open or close the manager panel under this button; answers the
    // panel host's reply.
    function toggle() {
        const reply = root.bar.shell.surfaces.toggle("panel", "{}", root);
        if (!Reply.isOk(reply)) console.warn("manager button: panel " + reply);
        return reply;
    }

    Text {
        id: label
        anchors.centerIn: parent
        text: "Plugins"
        color: Color.bar.text
        font.family: Style.font.family
        font.pixelSize: Style.font.size
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.toggle()
    }
}
