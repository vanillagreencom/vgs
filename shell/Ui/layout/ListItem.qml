import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// One row of a list: an optional icon, a text with an optional secondary
// line under it, and `trailing` items at the end, such as a badge or a
// switch. Both lines draw at line height 1, `row.lineGap` apart, so the
// pair's glyphs sit on the row's centre with the icon; a row with a
// secondary line is `listItem.twoLineHeight` tall, one without
// `listItem.height`. The template owns the click, `highlighted` and the keyboard;
// the fill follows hover, press and highlight.
T.ItemDelegate {
    id: root

    property string iconName: ""
    property string secondary: ""
    property alias trailing: trailingRow.data

    implicitWidth: leftPadding + rightPadding + (iconName !== "" ? Theme.icon.size.md + Theme.listItem.iconGap : 0) + Math.max(title.implicitWidth, secondaryLabel.implicitWidth) + (trailingRow.width > 0 ? trailingRow.width + Theme.listItem.gap : 0)
    implicitHeight: Math.max(secondary !== "" ? Theme.listItem.twoLineHeight : Theme.listItem.height, implicitContentHeight + topPadding + bottomPadding)
    leftPadding: Theme.listItem.paddingX
    rightPadding: Theme.listItem.paddingX
    spacing: Theme.listItem.gap
    hoverEnabled: true
    PointerCursor {}
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text

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
        color: root.highlighted ? Theme.listItem.selected : root.down || root.hovered ? Theme.listItem.hover : "transparent"
        Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
        FocusRing { target: root }
    }
}
