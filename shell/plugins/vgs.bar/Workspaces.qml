import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Workspace numbers from the shared Workspaces token, one BarItem pill
// each: its label plus `bar.item.paddingX` a side, never narrower than it
// is tall, `bar.item.height` tall, the focused one filled with
// `bar.active`, on the bar's vertical centre. Focusing one goes through
// the bar's own compositor capability, which checks the argument and
// judges the reply.
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

            BarItem {
                id: pill
                required property int modelData

                Layout.alignment: Qt.AlignVCenter
                text: String(modelData)
                active: Workspaces.focusedId === modelData
                onClicked: root.bar.shell.compositor.focusWorkspace(pill.modelData)
            }
        }
    }
}
