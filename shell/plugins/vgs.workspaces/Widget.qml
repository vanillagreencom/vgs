import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Workspace numbers. Reads the compositor's workspace list; focusing one
// goes through the core's compositor capability, which judges the reply.
BarWidget {
    id: root
    moduleName: "vgs.workspaces"

    readonly property var shell: bar ? bar.shell : null

    function ids() {
        const out = [];
        for (const ws of Hyprland.workspaces.values)
            if (ws.id > 0) out.push(ws.id);
        return out;
    }

    implicitWidth: row.implicitWidth
    implicitHeight: barSize

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: Style.spacing.sm

        Repeater {
            model: root.ids()

            Rectangle {
                required property int modelData
                readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData

                Layout.preferredWidth: Style.space(5)
                Layout.preferredHeight: root.barSize - Style.spacing.md
                radius: Style.cornerRadius
                color: focused ? Color.bar.active : "transparent"

                Text {
                    anchors.centerIn: parent
                    text: String(parent.modelData)
                    color: parent.focused ? Color.background : Color.bar.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.size
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.shell.compositor.focusWorkspace(parent.modelData)
                }
            }
        }
    }
}
