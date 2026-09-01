import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "sysUpdate"

    readonly property string defaultSystemCommand: "{vshell} update run system"
    readonly property string defaultAurCommand: "{vshell} update run aur"
    readonly property string defaultToolsCommand: "{vshell} update run tools"
    readonly property string defaultAllCommand: "{vshell} update run all"

    StyledText {
        width: parent.width
        text: "System Updates Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Choose the shell commands used by the System Updates popout buttons. A button left on its default runs through the VGS backend, which watches the terminal and re-counts when it closes. A custom command runs in a floating terminal through `sh -lc`, so shell syntax and environment variables work. Use `{vshell}` for the VGS CLI path and `{home}` for your home directory."
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
                settingKey: "systemUpdateCommand"
                label: "System update command"
                description: "Runs when clicking Update System. Default updates repo packages with the VGS helper."
                placeholder: root.defaultSystemCommand
                defaultValue: root.defaultSystemCommand
            }

            StringSetting {
                settingKey: "aurUpdateCommand"
                label: "AUR update command"
                description: "Runs when clicking Update AUR. Default updates AUR packages with the VGS helper when paru is available."
                placeholder: root.defaultAurCommand
                defaultValue: root.defaultAurCommand
            }

            StringSetting {
                settingKey: "toolsUpdateCommand"
                label: "Dev tools update command"
                description: "Runs when clicking Update Dev Tools. Default runs mise up for coding agents and language toolchains, then refreshes their launchers."
                placeholder: root.defaultToolsCommand
                defaultValue: root.defaultToolsCommand
            }

            StringSetting {
                settingKey: "allUpdateCommand"
                label: "Update all command"
                description: "Runs when clicking Update All. Set this when your repo and AUR flows need special sequencing."
                placeholder: root.defaultAllCommand
                defaultValue: root.defaultAllCommand
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
                    text: "Examples"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                width: parent.width
                text: "Portable defaults:\n    {vshell} update run system\n    {vshell} update run aur\n    {vshell} update run tools\n    {vshell} update run all\n\nPersonal wrappers:\n    $HOME/.local/bin/sysupdate-run system\n    $HOME/.local/bin/sysupdate-run aur\n    $HOME/.local/bin/sysupdate-run all"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                lineHeight: 1.4
            }
        }
    }
}
