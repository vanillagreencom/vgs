import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// One entry of a Menu: an optional icon, the text, an optional key
// shortcut hint, and a check mark at the end while `checked` holds, which
// marks the current choice. The template owns the click, `triggered` and
// the hover; the menu sets `highlighted` for the keyboard. `shortcut` is a
// hint drawn after the text, not a binding; a click never toggles
// `checked`, which the author binds.
T.MenuItem {
    id: root

    property string iconName: ""
    property string shortcut: ""

    width: parent ? parent.width : implicitWidth
    implicitWidth: implicitContentWidth + leftPadding + rightPadding
    implicitHeight: Math.max(Theme.menu.item.height, implicitContentHeight + topPadding + bottomPadding)
    leftPadding: Theme.menu.item.paddingX
    rightPadding: Theme.menu.item.paddingX + (checked ? Theme.icon.size.sm + spacing : 0)
    spacing: Theme.menu.item.gap
    hoverEnabled: true
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text
    Accessible.checked: checked

    contentItem: Row {
        spacing: root.spacing
        Icon {
            visible: root.iconName !== ""
            name: root.iconName
            size: Theme.icon.size.sm
            color: Theme.menu.item.foreground
            anchors.verticalCenter: parent.verticalCenter
        }
        Label {
            role: "item"
            text: root.text
            color: Theme.menu.item.foreground
            anchors.verticalCenter: parent.verticalCenter
        }
        Label {
            role: "hint"
            text: root.shortcut
            visible: root.shortcut !== ""
            color: Theme.menu.item.shortcut
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    // The check mark stands in the right padding, which grows to hold it
    // while the entry is checked.
    indicator: Icon {
        name: "check"
        visible: root.checked
        size: Theme.icon.size.sm
        color: Theme.menu.item.check
        x: root.width - Theme.menu.item.paddingX - width
        y: (root.height - height) / 2
    }

    background: Rectangle {
        radius: Theme.menu.item.radius
        color: root.highlighted || root.hovered || root.down ? Theme.menu.item.hover : "transparent"
    }
}
