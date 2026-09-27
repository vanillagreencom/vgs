import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// One row of a list: an optional icon, a text with an optional secondary
// line under it, and `trailing` items at the end, such as a badge or a
// switch. The template owns the click, `highlighted` and the keyboard;
// the fill follows hover, press and highlight.
T.ItemDelegate {
    id: root

    property string iconName: ""
    property string secondary: ""
    property alias trailing: trailingRow.data

    implicitWidth: leftPadding + rightPadding + (iconName !== "" ? Theme.icon.size.md + spacing : 0) + Math.max(title.implicitWidth, secondaryLabel.implicitWidth) + (trailingRow.width > 0 ? trailingRow.width + spacing : 0)
    implicitHeight: Math.max(Theme.listItem.height, implicitContentHeight + topPadding + bottomPadding)
    leftPadding: Theme.listItem.paddingX
    rightPadding: Theme.listItem.paddingX
    spacing: Theme.listItem.gap
    hoverEnabled: true
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text

    contentItem: Row {
        spacing: root.spacing
        Icon {
            visible: root.iconName !== ""
            name: root.iconName
            size: Theme.icon.size.md
            color: root.highlighted ? Theme.listItem.selectedForeground : Theme.color.textMuted
            anchors.verticalCenter: parent.verticalCenter
        }
        Column {
            width: parent.width - (parent.children[0].visible ? parent.children[0].width + parent.spacing : 0) - (trailingRow.width > 0 ? trailingRow.width + parent.spacing : 0)
            anchors.verticalCenter: parent.verticalCenter
            Label {
                id: title
                role: "body"
                text: root.text
                color: root.highlighted ? Theme.listItem.selectedForeground : Theme.color.text
                width: parent.width
                elide: Text.ElideRight
            }
            Label {
                id: secondaryLabel
                role: "hint"
                text: root.secondary
                visible: root.secondary !== ""
                width: parent.width
                elide: Text.ElideRight
            }
        }
        Row {
            id: trailingRow
            spacing: Theme.listItem.gap
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
