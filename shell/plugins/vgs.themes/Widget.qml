import QtQuick
import qs.Commons
import qs.Ui

// The themes button: one icon button that opens the plugin's own panel
// under it, or closes it when it is open.
BarWidget {
    id: root

    implicitWidth: button.implicitWidth
    implicitHeight: barSize

    // Open or close the themes panel under this widget; answers the panel
    // host's reply.
    function toggle() {
        const reply = shell.surfaces.toggle("panel", "{}", root);
        if (reply !== "ok") console.warn("themes widget: panel " + reply);
        return reply;
    }

    IconButton {
        id: button
        anchors.centerIn: parent
        size: "sm"
        iconName: "palette"
        label: "Themes"
        onClicked: root.toggle()
    }
}
