import QtQuick
import qs.Commons
import qs.Ui

// The Settings gear in the bar: a click opens or closes the Settings
// window. Hyprland maps a new window on the focused monitor, and the
// pointer on this bar has made its screen the focused one.
BarWidget {
    id: root

    implicitWidth: button.implicitWidth
    implicitHeight: barSize

    // Open or close the Settings window; answers the window host's reply.
    function toggle() {
        const reply = shell.surfaces.toggle("window", "{}");
        if (reply !== "ok") console.warn("settings: gear " + reply);
        return reply;
    }

    IconButton {
        id: button
        anchors.centerIn: parent
        size: "sm"
        iconName: "settings"
        label: "Settings"
        onClicked: root.toggle()
    }
}
