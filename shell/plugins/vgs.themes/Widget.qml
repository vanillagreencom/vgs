import QtQuick
import qs.Commons
import qs.Ui

// The themes button: one BarItem, the palette alone in the bar's own
// colour, that opens the plugin's own panel under it, or closes it when it
// is open.
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

    function shortcut() {
        return root.shell !== null && root.shell.shortcut !== undefined && root.shell.shortcut.keys !== undefined
            ? (root.shell.shortcut.keys.panel || "")
            : "";
    }

    BarItem {
        id: button
        anchors.centerIn: parent
        iconName: "palette"
        label: "Themes"
        shortcut: root.shortcut()
        tone: root.bar ? root.bar.foreground : "transparent"
        onClicked: root.toggle()
    }
}
