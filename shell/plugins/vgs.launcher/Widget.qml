import QtQuick
import qs.Ui
import "Appearance.js" as Appearance
import qs.Commons

// The launcher's bar entry: a magnifier in the bar's own colour. A left
// click opens or closes the launcher on this bar's screen; a right click
// opens a terminal, as the reference entry did.
BarWidget {
    id: root

    readonly property var look: Theme.appearance(Appearance.TOKENS, Appearance.LIGHT)

    implicitWidth: look === null ? 0 : icon.implicitWidth + 2 * look.bar.paddingX
    implicitHeight: barSize

    Icon {
        id: icon
        anchors.centerIn: parent
        visible: root.look !== null
        name: "search"
        size: root.look === null ? 0 : root.look.bar.icon
        stroke: root.look === null ? 0 : root.look.bar.stroke
        color: root.bar ? root.bar.foreground : "transparent"
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => {
            if (root.shell === null) return;
            const reply = mouse.button === Qt.RightButton ? root.shell.run.detached(["xdg-terminal-exec"]) : root.shell.surfaces.toggle("overlay", "{}");
            if (reply !== "ok") console.warn("launcher: bar entry " + reply);
        }
    }
}
