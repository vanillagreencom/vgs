import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Workspace numbers from the shared Workspaces token, one pill each. A pill
// is its label plus `bar.item.paddingX` a side, never narrower than
// `size.control.sm`, and its label's line height plus `space.xs` tall; the
// label sits at the pill's centre and the pill at the bar's vertical
// centre. Focusing one goes through the bar's own compositor capability,
// which checks the argument and judges the reply.
Item {
    id: root

    // The bar, read for its `shell` alone.
    required property Item bar

    implicitWidth: row.implicitWidth
    implicitHeight: Theme.bar.height

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: Theme.bar.item.gap

        Repeater {
            model: Workspaces.ids

            Rectangle {
                id: pill
                required property int modelData
                readonly property bool focused: Workspaces.focusedId === modelData

                Layout.alignment: Qt.AlignVCenter
                Layout.preferredWidth: Math.max(Theme.size.control.sm, label.implicitWidth + 2 * Theme.bar.item.paddingX)
                Layout.preferredHeight: label.implicitHeight + Theme.space.xs
                radius: Theme.bar.item.radius
                color: focused ? Theme.bar.active : "transparent"
                Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }

                Label {
                    id: label
                    anchors.centerIn: parent
                    role: "bar"
                    text: String(pill.modelData)
                    color: pill.focused ? Theme.bar.onActive : Theme.bar.foreground
                }

                MouseArea {
                    anchors.fill: parent
                    PointerCursor {}
                    onClicked: root.bar.shell.compositor.focusWorkspace(pill.modelData)
                }
            }
        }
    }
}
