import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Workspace numbers from the shared Workspaces token. Focusing one goes
// through the bar's own compositor capability, which checks the argument
// and judges the reply.
Item {
    id: root

    // The bar, read for its `shell` alone.
    required property Item bar

    implicitWidth: row.implicitWidth
    implicitHeight: Theme.bar.height

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: Theme.space.xs

        Repeater {
            model: Workspaces.ids

            Rectangle {
                required property int modelData
                readonly property bool focused: Workspaces.focusedId === modelData

                Layout.preferredWidth: Theme.size.control.sm
                Layout.preferredHeight: Theme.bar.height - Theme.space.sm
                radius: Theme.radius.sm
                color: focused ? Theme.bar.active : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }

                Label {
                    anchors.centerIn: parent
                    role: "body"
                    text: String(parent.modelData)
                    color: parent.focused ? Theme.bar.onActive : Theme.bar.foreground
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.bar.shell.compositor.focusWorkspace(parent.modelData)
                }
            }
        }
    }
}
