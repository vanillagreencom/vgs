import QtQuick
import QtQuick.Layouts
import qs.Commons

// Workspace numbers from the shared Workspaces token. Focusing one goes
// through the bar's own compositor capability, which checks the argument
// and judges the reply.
Item {
    id: root

    // The bar, read for its `shell` alone.
    required property Item bar

    implicitWidth: row.implicitWidth
    implicitHeight: Style.bar.sizeHorizontal

    // Focus workspace `id`; answers the capability's reply. Not `focus`,
    // which every Item already has as a property.
    function focusWorkspace(id) {
        return root.bar.shell.compositor.focusWorkspace(Number(id));
    }

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
                Layout.preferredHeight: Style.bar.sizeHorizontal - Style.spacing.md
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
                    onClicked: root.focusWorkspace(parent.modelData)
                }
            }
        }
    }
}
