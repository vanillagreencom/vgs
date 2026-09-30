import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// One row of a list: an optional icon, a text with an optional secondary
// line under it, and `trailing` items at the end, such as a badge or a
// switch. Both lines draw at line height 1, `row.lineGap` apart, so the
// pair's glyphs sit on the row's centre with the icon; a row with a
// secondary line is `listItem.twoLineHeight` tall, one without
// `listItem.height`. The template owns the click, `highlighted` and the keyboard.
//
// A row of a list that declares a ListCursor names it in `cursor`: the
// cursor then draws the highlight and travels to the row while it is
// `highlighted`, a hover the cursor lets through emits `pointed` for the
// list to select the row, and the row enters through ListEntrance when it
// is created, unless `enters` is false, as for a view that creates rows as
// they scroll in. Without a cursor the row's own fill follows hover, press
// and highlight. Under a rounded theme the side padding grows until the
// content clears the drawn corner.
T.ItemDelegate {
    id: root

    property string iconName: ""
    property string secondary: ""
    property alias trailing: trailingRow.data
    property ListCursor cursor: null
    property bool enters: cursor !== null

    signal pointed()

    implicitWidth: leftPadding + rightPadding + (iconName !== "" ? Theme.icon.size.md + Theme.listItem.iconGap : 0) + Math.max(title.implicitWidth, secondaryLabel.implicitWidth) + (trailingRow.width > 0 ? trailingRow.width + Theme.listItem.gap : 0)
    implicitHeight: Math.max(secondary !== "" ? Theme.listItem.twoLineHeight : Theme.listItem.height, implicitContentHeight + topPadding + bottomPadding)
    leftPadding: Theme.controlPadding(Theme.listItem.paddingX, Theme.listItem.radius, Math.max(secondary !== "" ? Theme.listItem.twoLineHeight : Theme.listItem.height, height), implicitContentHeight)
    rightPadding: leftPadding
    spacing: Theme.listItem.gap
    hoverEnabled: true
    PointerCursor {}
    opacity: (enabled ? 1 : Theme.opacity.disabled) * entrance.progress
    Accessible.name: text

    transform: ListEntrance { id: entrance; motion: root.cursor !== null ? root.cursor.motion : Theme.motion.list }
    Component.onCompleted: if (enters && cursor !== null) entrance.start(cursor.enterSlot(), 0)

    ListCursorRow {
        cursor: root.cursor
        holds: root.highlighted
        onPointed: root.pointed()
    }

    contentItem: Item {
        implicitWidth: (icon.visible ? icon.width + Theme.listItem.iconGap : 0) + Math.max(title.implicitWidth, secondaryLabel.implicitWidth) + (trailingRow.width > 0 ? trailingRow.width + Theme.listItem.gap : 0)
        implicitHeight: Math.max(icon.implicitHeight, lines.implicitHeight, trailingRow.implicitHeight)

        Icon {
            id: icon
            visible: root.iconName !== ""
            name: root.iconName
            size: Theme.icon.size.md
            color: root.highlighted ? Theme.listItem.selectedForeground : Theme.color.textMuted
            anchors.verticalCenter: parent.verticalCenter
        }
        Column {
            id: lines
            x: icon.visible ? icon.width + Theme.listItem.iconGap : 0
            width: Math.max(0, parent.width - x - (trailingRow.width > 0 ? trailingRow.width + Theme.listItem.gap : 0))
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.row.lineGap
            Label {
                id: title
                role: "item"
                text: root.text
                color: root.highlighted ? Theme.listItem.selectedForeground : Theme.color.text
                width: parent.width
                elide: Text.ElideRight
            }
            Label {
                id: secondaryLabel
                role: "itemHint"
                text: root.secondary
                visible: root.secondary !== ""
                width: parent.width
                elide: Text.ElideRight
            }
        }
        Row {
            id: trailingRow
            spacing: Theme.listItem.gap
            x: parent.width - width
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    background: Rectangle {
        radius: Theme.listItem.radius
        color: root.cursor !== null ? "transparent" : root.highlighted ? (root.down ? Theme.listItem.selectedPressed : Theme.listItem.selected) : root.down ? Theme.listItem.pressed : root.hovered ? Theme.listItem.hover : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
        FocusRing { target: root }
    }
}
