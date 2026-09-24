import QtQuick
import qs.Commons

// The plugin manager's button. A click opens the bar's own manager panel
// under the button, or closes it when it is open.
Item {
    id: root

    required property Item bar

    implicitWidth: label.implicitWidth + Style.spacing.lg
    implicitHeight: bar.barSize

    // Open or close the manager panel under this button; answers the
    // panel host's reply.
    function toggle() {
        return root.bar.shell.surfaces.toggle("panel", "{}", root);
    }

    Text {
        id: label
        anchors.centerIn: parent
        text: "Plugins"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.size
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.toggle()
    }
}
