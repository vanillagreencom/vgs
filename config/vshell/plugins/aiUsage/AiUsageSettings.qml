import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// The AI Usage page in the settings app. Everything on it also lives behind the
// filter in the widget's own popout; both surfaces embed AiUsageProviderSetup,
// so neither can offer a source the other does not.
//
// The API key is the one thing here that does NOT go through saveValue() —
// AiUsageProviderSetup says why.
PluginSettings {
    id: root
    pluginId: "aiUsage"

    AiUsageLogic {
        id: catalog
    }

    StyledText {
        width: parent.width
        text: "AI Usage Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Show Claude Code, OpenAI Codex and Vercel AI Gateway usage in the bar — one labelled slot per provider. Click the widget for per-account limits, to filter which providers count, and to tell a provider where its accounts are."
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

            StringSetting {
                settingKey: "refreshSeconds"
                label: "Refresh Interval (seconds)"
                description: "How often to poll usage. The provider usage APIs rate-limit aggressively; keep this at 300 or higher."
                placeholder: "300"
                defaultValue: "300"
            }
        }
    }

    // One section per provider: an API key field for the providers configured
    // with one, and the config directories the others are discovered in. The
    // popout shows the same component one provider at a time.
    Column {
        width: parent.width
        spacing: Theme.spacingL

        Repeater {
            model: catalog.providerOrder()

            AiUsageProviderSetup {
                required property string modelData

                width: parent.width
                provider: modelData
                // Every section is on screen here, unlike the popout's one page.
                active: true
                onSourcesChanged: root.saveValue("sourcesStamp", Date.now())
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
                text: "Backed by `vshell ai-usage`, which wraps the claudebar/codexbar engines and calls the AI Gateway REST API directly.\n\n• Claude: log in with the 'claude' CLI (reads ~/.claude/.credentials.json)\n• Codex: log in with 'codex login' (reads ~/.codex)\n• AI Gateway: add an API key in the widget's provider setup, or export AI_GATEWAY_API_KEY\n\nExtra Claude and Codex accounts are picked up automatically: any config directory holding its own login (the ones your CLAUDE_CONFIG_DIR / CODEX_HOME wrappers point at) is listed separately, labelled by its signed-in address. A wrapper pointing somewhere no naming convention can guess is added by hand in provider setup. Profiles whose tokens live in the desktop keyring can't be polled and are left out. AI Gateway keys are stored in a private 0600 file under ~/.local/state/vshell, never in this settings file.\n\nThe bar keeps one slot per provider, each with its own icon and in a fixed order, so a number never changes meaning; a vertical bar stacks them. A slot shows that provider's usage %: each account counts at its tightest window, and the Bar number setting in the popout chooses how several of them combine — averaged by default, or the account with the most headroom, or the most used. A slot reads an exclamation mark instead when that provider answered and the answer was unusable — not signed in, or the usage API failed; an ellipsis while a fetch for it is running; and a dash when the provider is fine but there is nothing left to show, which is every one of its accounts hidden.\n\nClick the widget for one card per account, whichever provider it belongs to, with session, weekly, per-model and credit limits and reset countdowns; clicking a card expands it. The filter at the top chooses which providers count, and each row there opens that provider's setup."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }
        }
    }
}
