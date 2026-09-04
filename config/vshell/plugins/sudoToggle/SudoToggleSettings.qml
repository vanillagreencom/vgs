import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Allow the user to restore grant confirmation after suppressing it.
PluginSettings {
    id: root
    pluginId: "sudoToggle"

    StyledText {
        width: parent.width
        text: I18n.tr("Passwordless Sudo Settings", "Plugin settings page title")
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: I18n.tr("Granting passwordless sudo installs a permanent NOPASSWD rule for your user, with no expiry. Revoking is never confirmed — it only ever removes privilege.", "Plugin settings description")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledRect {
        width: parent.width
        height: configColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.borderColor

        Column {
            id: configColumn

            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            // Shown the right way round: the switch is on when the shell asks.
            // The stored key is the suppression, so this inverts it.
            VgsToggle {
                width: parent.width
                horizontalPadding: 0
                text: I18n.tr("Confirm before granting", "Setting: show the sudo grant confirmation modal")
                description: I18n.tr("Ask for confirmation in a dialog before installing the passwordless sudo rule", "Setting description")
                checked: !SettingsData.sudoToggleSkipGrantConfirm
                onToggled: checked => SettingsData.set("sudoToggleSkipGrantConfirm", !checked)
            }
        }
    }
}
