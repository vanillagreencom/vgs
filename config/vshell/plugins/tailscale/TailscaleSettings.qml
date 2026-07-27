import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "tailscale"

    StyledText {
        width: parent.width
        text: "Tailscale Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Show Tailscale mesh-VPN state in the bar. Click the pill to connect/disconnect, pick an exit node, and browse tailnet devices."
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
                settingKey: "pillMode"
                label: "Pill label"
                description: "What the bar pill shows next to the icon"
                defaultValue: "status"
                options: [
                    { value: "icon", label: "Icon only" },
                    { value: "status", label: "Status (On/Off/Login)" },
                    { value: "count", label: "Online device count" },
                    { value: "tailnet", label: "Tailnet name" }
                ]
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
                text: "Needs the `tailscale` CLI with tailscaled running. Read-only status works as your user. Connect/disconnect, exit-node and route toggles require the Tailscale operator to be your user — run once:\n\n    sudo tailscale set --operator=$USER\n\nConnecting while logged out opens the Tailscale login page in your browser."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }
        }
    }
}
