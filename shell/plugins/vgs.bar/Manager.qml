import QtQuick
import qs.Commons

// The plugin manager's button. A click opens the bar's own manager panel
// under the button, or closes it when it is open.
Item {
    id: root

    // The bar goes before its built-ins when a screen goes away, so every
    // binding reads it through a null check.
    required property Item bar

    implicitWidth: label.implicitWidth + Style.spacing.lg
    implicitHeight: root.bar ? root.bar.barSize : Style.bar.sizeHorizontal

    // Open or close the manager panel under this button; answers the
    // panel host's reply.
    function toggle() {
        const reply = root.bar.shell.surfaces.toggle("panel", "{}", root);
        if (reply !== "ok") console.warn("manager button: panel " + reply);
        return reply;
    }

    Text {
        id: label
        anchors.centerIn: parent
        text: "Plugins"
        color: (root.bar ? root.bar.foreground : Color.bar.text)
        font.family: (root.bar ? root.bar.fontFamily : Style.font.family)
        font.pixelSize: Style.font.size
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.toggle()
    }
}
