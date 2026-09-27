import QtQuick
import qs.Commons
import qs.Ui
import "Reply.js" as Reply

// The plugin manager's button. A click opens the bar's own manager panel
// under the button, or closes it when it is open.
Item {
    id: root

    // The bar, read for its `shell` alone.
    required property Item bar

    implicitWidth: button.implicitWidth
    implicitHeight: Theme.bar.height

    // Open or close the manager panel under this button; answers the
    // panel host's reply.
    function toggle() {
        const reply = root.bar.shell.surfaces.toggle("panel", "{}", root);
        if (!Reply.isOk(reply)) console.warn("manager button: panel " + reply);
        return reply;
    }

    Button {
        id: button
        anchors.centerIn: parent
        variant: "ghost"
        size: "sm"
        iconName: "layout-grid"
        text: "Plugins"
        onClicked: root.toggle()
    }
}
