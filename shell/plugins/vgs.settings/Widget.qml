import QtQuick
import qs.Commons
import qs.Ui

// The Settings gear in the bar: a click opens or closes the Settings
// window, centred on this bar's screen.
BarWidget {
    id: root

    implicitWidth: button.implicitWidth
    implicitHeight: barSize

    // Open or close the Settings window; answers the panel host's reply.
    function toggle() {
        const reply = shell.surfaces.toggle("panel", "{}");
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
