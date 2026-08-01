pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Settings.Widgets

// The Settings app's card, plus a description slot. Cloud Sync is a
// settings-shaped product, so it inherits SettingsCard's fill, hairline border,
// radius, header typography and padding rather than restating them.
//
// Children declared here land in contentColumn ahead of the use site's, so the
// description always renders directly under the title.
SettingsCard {
    id: root

    property string description: ""
    // Marks the card a cross-page jump landed on. SettingsCard's own highlight
    // is wired to the settings search service, which Cloud Sync does not use.
    // Expressed as the card's own border rather than an overlay child: this
    // component's default children land in SettingsCard's content column, so a
    // declared Rectangle would render inside the card instead of around it.
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
