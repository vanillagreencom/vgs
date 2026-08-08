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
        text: "Show Claude Code or OpenAI Codex subscription usage in the bar. Click the widget to switch providers and see the full breakdown; the gear inside that popout holds the display options — which number the bar shows, renewal dates, and which accounts are listed."
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
                text: "Backed by the 'ai-usage' helper (in ~/.local/bin), which wraps the claudebar/codexbar engines.\n\n• Claude: log in with the 'claude' CLI (reads ~/.claude/.credentials.json)\n• Codex: log in with 'codex login' (reads ~/.codex)\n\nExtra accounts are picked up automatically: any config directory holding its own login (the ones your CLAUDE_CONFIG_DIR / CODEX_HOME wrappers point at) is listed separately, labelled by its signed-in email. Profiles whose tokens live in the desktop keyring can't be polled and are left out.\n\nThe bar pill shows the session (5h) usage %, colored by the worst active window — across all accounts when you have more than one. Click it for session, weekly and per-model limits with reset countdowns; with several accounts you get a per-account overview, and clicking a row expands it."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }
        }
    }
}
