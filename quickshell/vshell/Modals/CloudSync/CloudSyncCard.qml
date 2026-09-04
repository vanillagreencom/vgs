pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Settings.Widgets

// SettingsCard with a description slot. Its declared children precede caller content, placing the description below the title.
SettingsCard {
    id: root

    property string description: ""
    // Mark cross-page navigation with the card border. A default Rectangle child would land inside the content column.
    property bool highlighted: false

    width: parent ? parent.width : 0
    border.width: root.highlighted ? 2 : 1
    border.color: root.highlighted ? Theme.primary : Theme.borderColor

    Behavior on border.color {
        ColorAnimation {
            duration: Theme.shortDuration
            easing.type: Theme.standardEasing
        }
    }

    StyledText {
        width: parent.width
        visible: root.description.length > 0
        text: root.description
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
        lineHeight: 1.35
        lineHeightMode: Text.ProportionalHeight
    }
}
