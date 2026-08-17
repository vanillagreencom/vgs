pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

Column {
    id: root

    required property var options

    width: parent ? parent.width : 0
    spacing: Theme.spacingS
    visible: options.widgetId === "privacyIndicator"

    StyledText {
        width: parent.width
        text: I18n.tr("Always-On Icons")
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        rowHoverHighlight: false
        text: I18n.tr("Microphone")
        checked: SettingsData.privacyShowMicIcon
        onToggled: value => SettingsData.set("privacyShowMicIcon", value)
    }
    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        rowHoverHighlight: false
        text: I18n.tr("Camera")
        checked: SettingsData.privacyShowCameraIcon
        onToggled: value => SettingsData.set("privacyShowCameraIcon", value)
    }
    VgsToggle {
        width: parent.width
        horizontalPadding: 0
        rowHoverHighlight: false
        text: I18n.tr("Screen Sharing")
        checked: SettingsData.privacyShowScreenShareIcon
        onToggled: value => SettingsData.set("privacyShowScreenShareIcon", value)
    }
}
