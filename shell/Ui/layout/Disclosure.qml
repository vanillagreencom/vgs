import QtQuick
import qs.Commons
import qs.Ui

// A list row that shows or hides the content declared inside it: a
// `ListItem` whose click or Space toggles `expanded`, with its `trailing`
// items and then a chevron that points down while the content is hidden
// and up while it shows. A row that cannot expand keeps the chevron's room
// with nothing drawn in it, so the trailing items of a list of rows stand
// in one column. The content stacks under the row and takes no
// height while hidden. A control among the trailing items takes its own
// click, so pressing it toggles nothing. While `expandable` is false, as
// for a row with nothing to show, the row draws no chevron and a click
// toggles nothing. The content starts at the row's text column, the row's
// padding plus its icon and icon gap, and ends at the row's padding. The
// caller sets the width.
Column {
    id: root

    property alias text: row.text
    property alias secondary: row.secondary
    property alias iconName: row.iconName
    property alias trailing: extra.data
    property bool expanded: false
    property bool expandable: true
    default property alias content: body.data

    ListItem {
        id: row
        width: root.width
        onClicked: if (root.expandable) root.expanded = !root.expanded
        trailing: [
            Row {
                id: extra
                spacing: Theme.listItem.gap
                anchors.verticalCenter: parent.verticalCenter
            },
            Icon {
                opacity: root.expandable ? 1 : 0
                name: root.expanded ? "chevron-up" : "chevron-down"
                size: Theme.icon.size.md
                color: Theme.color.textMuted
                anchors.verticalCenter: parent.verticalCenter
            }
        ]
    }

    Column {
        id: body
        readonly property real inset: row.leftPadding + (root.iconName !== "" ? Theme.icon.size.md + Theme.listItem.iconGap : 0)
        x: inset
        width: Math.max(0, root.width - inset - row.rightPadding)
        visible: root.expandable && root.expanded
    }
}
