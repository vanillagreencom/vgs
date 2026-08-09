import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "remoteDesktop"

    StyledText {
        width: parent.width
        text: "Remote Desktop Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Start and stop the Sunshine remote-desktop host from the bar, and see at a glance when somebody is actually streaming this machine."
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
                    { value: "status", label: "Status (LIVE/On/Off)" }
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
                text: "Needs Sunshine installed with its user service present. The service is never enabled: the host starts only when you turn it on here, and stops when you turn it off, so nothing listens on an ordinary local session.\n\nOn Hyprland the virtual output the host captures is created on start and removed on stop, so no phantom monitor is left behind. Sunshine chooses its capture target at startup, so the two are done together by `vshell remote-desktop start` — starting the service by hand would leave it capturing a real monitor with nothing to say so.\n\nThe pill turns red and reads LIVE only while a client is connected. \"On\" means the host is listening and nobody is watching."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }
        }
    }
}
