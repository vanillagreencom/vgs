import QtQuick
import qs.Ui

// The launcher's bar entry: a magnifier in the bar's own colour, drawn as
// the shared BarItem so it matches the bar's other entries whatever the
// launcher's own look. A left click opens or closes the launcher on this
// bar's screen; a right click opens a terminal, as the reference entry
// did.
BarWidget {
    id: root

    implicitWidth: item.implicitWidth
    implicitHeight: barSize

    function open(button) {
        if (root.shell === null) return;
        const reply = button === Qt.RightButton ? root.shell.run.detached(["xdg-terminal-exec"]) : root.shell.surfaces.toggle("overlay", "{}");
        if (reply !== "ok") console.warn("launcher: bar entry " + reply);
    }

    BarItem {
        id: item
        anchors.centerIn: parent
        label: "Launcher"
        iconName: "search"
        tone: root.bar ? root.bar.foreground : "transparent"
        onClicked: root.open(Qt.LeftButton)

        // pointer-cursor-exempt: it adds the right click to the BarItem it sits in, whose own PointerCursor shows the hand
        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: root.open(Qt.RightButton)
        }
    }
}
