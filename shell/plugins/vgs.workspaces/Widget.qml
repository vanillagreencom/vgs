import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Workspace numbers. The id list comes from the shared Workspaces token, so
// every screen reads one derivation. Focusing one goes through this
// plugin's own compositor capability, which judges the reply.
BarWidget {
    id: root
    moduleName: "vgs.workspaces"

    implicitWidth: row.implicitWidth
    implicitHeight: barSize

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: Style.spacing.sm

        Repeater {
            model: Workspaces.ids

            Rectangle {
                required property int modelData
                readonly property bool focused: Workspaces.focusedId === modelData

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
