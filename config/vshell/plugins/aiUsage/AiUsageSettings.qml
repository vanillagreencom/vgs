import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "aiUsage"

    StyledText {
        width: parent.width
        text: "AI Usage Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Show Claude Code and OpenAI Codex subscription usage in the bar — one labelled slot each. Click the widget for the full breakdown and to switch which provider it opens on."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledRect {
        width: parent.width
        height: configColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: configColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            SelectionSetting {
                settingKey: "provider"
                label: "Provider"
                description: "Which AI subscription to display"
                defaultValue: "claude"
                options: [
                    { value: "claude", label: "Claude" },
                    { value: "codex", label: "Codex" }
                ]
            }

            StringSetting {
                settingKey: "refreshSeconds"
                label: "Refresh Interval (seconds)"
                description: "How often to poll usage. The provider usage APIs rate-limit aggressively; keep this at 300 or higher."
                placeholder: "300"
                defaultValue: "300"
            }
        }
    }

    StyledRect {
        width: parent.width
        height: infoColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surface

        Column {
            id: infoColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            Row {
                spacing: Theme.spacingM

                VgsIcon {
                    name: "info"
                    size: Theme.iconSize
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: "Requirements"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                width: parent.width
                text: "Backed by the 'ai-usage' helper (in ~/.local/bin), which wraps the claudebar/codexbar engines.\n\n• Claude: log in with the 'claude' CLI (reads ~/.claude/.credentials.json)\n• Codex: log in with 'codex login' (reads ~/.codex)\n\nExtra accounts are picked up automatically: any config directory holding its own login (the ones your CLAUDE_CONFIG_DIR / CODEX_HOME wrappers point at) is listed separately, labelled by its signed-in email. Profiles whose tokens live in the desktop keyring can't be polled and are left out.\n\nThe bar pill keeps one slot per provider, each with its own icon and in a fixed order, so a number never changes meaning. A slot shows that provider's usage %: each account counts at its tightest window, and the Bar number setting chooses how several of them combine — averaged by default, or the account with the most headroom, or the most used. A slot reads an exclamation mark instead when that provider answered and the answer was unusable — not signed in, or the usage API failed; an ellipsis while a fetch for it is running; and a dash when the provider is fine but there is nothing left to show, which is every one of its accounts hidden. Click it for session, weekly and per-model limits with reset countdowns; with several accounts you get a per-account overview, and clicking a row expands it."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }
        }
    }
}
