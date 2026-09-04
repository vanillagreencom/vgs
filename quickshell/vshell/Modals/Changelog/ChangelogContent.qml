import QtQuick
import QtQuick.Effects
import qs.Common
import qs.Services
import qs.Widgets

Column {
    id: root

    readonly property real logoSize: Math.round(Theme.iconSize * 2.8)
    readonly property real badgeHeight: Math.round(Theme.fontSizeSmall * 1.7)

    topPadding: Theme.spacingL
    spacing: Theme.spacingL

    Column {
        width: parent.width
        spacing: Theme.spacingM

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingM

            Image {
                width: root.logoSize
                height: width
                anchors.verticalCenter: parent.verticalCenter
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
                asynchronous: true
                source: "file://" + Theme.shellDir + "/assets/vgslogo.svg"
                layer.enabled: true
                layer.smooth: true
                layer.mipmap: true
                layer.effect: MultiEffect {
                    saturation: 0
                    colorization: 1
                    colorizationColor: Theme.primary
                }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                Row {
                    spacing: Theme.spacingS

                    StyledText {
                        text: "VGS " + ChangelogService.currentVersion
                        font.pixelSize: Theme.fontSizeXLarge + 2
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Rectangle {
                        width: codenameText.implicitWidth + Theme.spacingM * 2
                        height: root.badgeHeight
                        radius: root.badgeHeight / 2
                        color: Theme.primaryContainer
                        anchors.verticalCenter: parent.verticalCenter

                        visible: ShellVersionService.shellCodename.length > 0

                        StyledText {
                            id: codenameText
                            anchors.centerIn: parent
                            text: ShellVersionService.shellCodename
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.primary
                        }
                    }
                }

                StyledText {
                    text: "One launcher, a plugin system, and a theme engine of our own"
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                }
            }
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outlineMedium
        opacity: 0.3
    }

    Column {
        width: parent.width
        spacing: Theme.spacingM

        StyledText {
            text: "What's New"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        Grid {
            width: parent.width
            columns: 2
            rowSpacing: Theme.spacingS
            columnSpacing: Theme.spacingS

            ChangelogFeatureCard {
                width: (parent.width - Theme.spacingS) / 2
                iconName: "space_dashboard"
                title: "VGS Menu"
                description: "The one app launcher"
                onClicked: PluginService.toggleAppLauncher()
            }

            ChangelogFeatureCard {
                width: (parent.width - Theme.spacingS) / 2
                iconName: "extension"
                title: "Plugins"
                description: "Bundled & user plugins"
                onClicked: PopoutService.openSettingsWithTab("plugins")
            }

            ChangelogFeatureCard {
                width: (parent.width - Theme.spacingS) / 2
                iconName: "palette"
                title: "Themes & Colors"
                description: "Wallpaper palettes & app themes"
                onClicked: PopoutService.openSettingsWithTab("theme")
            }

            ChangelogFeatureCard {
                width: (parent.width - Theme.spacingS) / 2
                iconName: "brightness_medium"
                title: "Displays"
                description: "Layout, profiles & brightness"
                onClicked: PopoutService.openSettingsWithTab("display_config")
            }

            ChangelogFeatureCard {
                width: (parent.width - Theme.spacingS) / 2
                iconName: "bedtime"
                title: "Idle, Lock & Screensaver"
                description: "Lock, fade to black, screensavers"
                onClicked: PopoutService.openSettingsWithTab("screensaver")
            }

            ChangelogFeatureCard {
                width: (parent.width - Theme.spacingS) / 2
                iconName: "monitor_heart"
                title: "System Monitor"
                description: "Process list & resource view"
                onClicked: PopoutService.showProcessListModal()
            }

            ChangelogFeatureCard {
                width: (parent.width - Theme.spacingS) / 2
                iconName: "dock_to_bottom"
                title: "Dock"
                description: "Pinned apps & running windows"
                onClicked: PopoutService.openSettingsWithTab("dock")
            }

            ChangelogFeatureCard {
                width: (parent.width - Theme.spacingS) / 2
                iconName: "window"
                title: "Window Rules"
                description: "niri window rule manager"
                visible: CompositorService.isNiri
                onClicked: PopoutService.openSettingsWithTab("window_rules")
            }

            ChangelogFeatureCard {
                width: (parent.width - Theme.spacingS) / 2
                iconName: "notifications_active"
                title: "Notifications"
                description: "Configurable rules & styling"
                visible: !CompositorService.isNiri
                onClicked: PopoutService.openSettingsWithTab("notifications")
            }
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outlineMedium
        opacity: 0.3
    }

    Column {
        width: parent.width
        spacing: Theme.spacingS

        Row {
            spacing: Theme.spacingS

            VgsIcon {
                name: "warning"
                size: Theme.iconSizeSmall
                color: Theme.warning
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: "Upgrade Notes"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Rectangle {
            width: parent.width
            height: upgradeNotesColumn.height + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.warning, 0.08)
            border.width: 1
            border.color: Theme.withAlpha(Theme.warning, 0.2)

            Column {
                id: upgradeNotesColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingS

                ChangelogUpgradeNote {
                    width: parent.width
                    text: "Spotlight and the grid launcher are retired — the VGS Menu is now the only app launcher"
                }

                ChangelogUpgradeNote {
                    width: parent.width
                    text: "BREAKING: the launcher, spotlight and spotlight-bar IPC targets are removed — rebind keys to: vshell ipc call vshell-menu toggle"
                }

                ChangelogUpgradeNote {
                    width: parent.width
                    text: "Niri keybinds VGS generated are rewritten automatically; Hyprland binds live in your own config and must be updated by hand"
                }

            }
        }
    }
}
