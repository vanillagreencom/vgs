import QtQuick
import qs.Ui
import "AutomationsViewLogic.js" as View

ListItem {
    id: root

    required property var row
    property int index: 0
    property Item cursorItem: null
    property Item scrollArea: null

    signal openRequested(string transcript)

    width: parent ? parent.width : implicitWidth
    text: row.name
    iconName: ""
    secondary: View.formatWhen(row.startedAt) + " · " + View.formatDuration(row.durationMs)
    cursor: cursorItem
    onClicked: root.openRequested(row.transcript)
    onHighlightedChanged: if (highlighted && scrollArea !== null) {
        const top = root.mapToItem(scrollArea.contentItem, 0, 0).y;
        if (top < scrollArea.contentY) scrollArea.contentY = top;
        else if (top + root.height > scrollArea.contentY + scrollArea.height) scrollArea.contentY = top + root.height - scrollArea.height;
    }
    trailing: [
        Badge { text: View.outcomeLabel(root.row.outcome); tone: root.row.tone; iconName: root.row.icon; size: "sm"; anchors.verticalCenter: parent.verticalCenter }
    ]
}
