import QtQuick
import Quickshell
import qs.Common
import qs.Modals.FileBrowser
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

FocusScope {
    id: root
    property var parentModal: null
    property var cyclingIntervalOptions: [
        { label: I18n.tr("Every 5 minutes"), value: 300 },
        { label: I18n.tr("Every 15 minutes"), value: 900 },
        { label: I18n.tr("Every 30 minutes"), value: 1800 },
        { label: I18n.tr("Every hour"), value: 3600 },
        { label: I18n.tr("Every 3 hours"), value: 10800 }
    ]

    FileBrowserModal {
        id: wallpaperFolderBrowser
        browserTitle: I18n.tr("Pick any image inside your wallpaper folder")
        browserType: "wallpaper"
        showHiddenFiles: true
        fileExtensions: ["*.jpg", "*.jpeg", "*.png", "*.bmp", "*.gif", "*.webp", "*.jxl", "*.avif", "*.heif"]
        onFileSelected: path => {
            SettingsData.set("wallpaperFolder", path.substring(0, path.lastIndexOf("/")));
            close();
        }
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: mainColumn.height + Theme.spacingXL

        Column {
            id: mainColumn
            width: Math.min(760, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            topPadding: Theme.spacingS
            spacing: Theme.spacingXL


            SettingsCard {
                title: I18n.tr("Behavior")
                iconName: "tune"
                settingKey: "wallpaperBehavior"
                width: parent.width

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    // Open the Dash picker for folder and monitor controls. The separate shortcut opens the fullscreen switcher.
                    VgsButton {
                        variant: "secondary"
                        text: I18n.tr("Browse Wallpapers")
                        iconName: "wallpaper"
                        onClicked: {
                            const bar = KeyboardFocus.getPreferredBar("clockButtonRef") || KeyboardFocus.getPreferredBar();
                            if (bar)
                                bar.triggerDashTab(SettingsData.dashTabIndexForId("wallpaper"));
                        }
                    }

                    VgsButton {
                        variant: "secondary"
                        text: I18n.tr("Browse Themes")
                        iconName: "palette"
                        onClicked: {
                            const bar = KeyboardFocus.getPreferredBar("clockButtonRef") || KeyboardFocus.getPreferredBar();
                            if (bar)
                                bar.triggerDashTab(SettingsData.dashTabIndexForId("themes"));
                        }
                    }
                }

                SwitcherShortcutRow {
                    action: "spawn vshell ipc call wallpaper-switcher toggle"
                    text: I18n.tr("Wallpaper Switcher Shortcut")
                    bindDescription: I18n.tr("Wallpaper switcher")
                    panelWindow: root.parentModal
                }

                SettingsDropdownRow {
                    settingKey: "wallpaperFillMode"
                    tags: ["wallpaper", "fill", "scale"]
                    text: I18n.tr("Fill Mode")
                    options: ["Stretch", "Fit", "Fill", "Tile", "TileVertically", "TileHorizontally", "Pad"].map(m => I18n.tr(m, "wallpaper fill mode"))
                    currentValue: {
                        const modes = ["Stretch", "Fit", "Fill", "Tile", "TileVertically", "TileHorizontally", "Pad"];
                        const idx = modes.indexOf(SettingsData.wallpaperFillMode || "Fill");
                        return I18n.tr(modes[idx >= 0 ? idx : 2], "wallpaper fill mode");
                    }
                    onValueChanged: value => {
                        const modes = ["Stretch", "Fit", "Fill", "Tile", "TileVertically", "TileHorizontally", "Pad"];
                        const idx = modes.map(m => I18n.tr(m, "wallpaper fill mode")).indexOf(value);
                        if (idx >= 0)
                            SettingsData.set("wallpaperFillMode", modes[idx]);
                    }
                }

                SettingsToggleRow {
                    tab: "wallpaper"
                    tags: ["wallpaper", "theme", "source", "folder"]
                    settingKey: "wallpaperSource"
                    text: I18n.tr("Wallpapers Follow Theme")
                    description: I18n.tr("Use the theme wallpaper instead of your folder.")
                    checked: SettingsData.wallpaperSource !== "folder"
                    onToggled: checked => SettingsData.set("wallpaperSource", checked ? "theme" : "folder")
                }

                Item {
                    width: parent.width
                    height: wallpaperFolderField.height
                    visible: SettingsData.wallpaperSource === "folder"

                    VgsTextField {
                        id: wallpaperFolderField
                        width: parent.width
                        rightAccessoryWidth: pickFolderButton.width + Theme.spacingM
                        placeholderText: I18n.tr("Wallpaper folder (default: ~/Pictures/Wallpapers)")
                        text: SettingsData.wallpaperFolder
                        backgroundColor: Theme.surfaceContainerHighest
                        onEditingFinished: {
                            if (text !== SettingsData.wallpaperFolder)
                                SettingsData.set("wallpaperFolder", text);
                        }
                    }

                    VgsButton {
                        id: pickFolderButton
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        variant: "secondary"
                        text: I18n.tr("Browse")
                        onClicked: wallpaperFolderBrowser.open()
                    }
                }

                SettingsToggleRow {
                    tab: "wallpaper"
                    tags: ["wallpaper", "monitor", "per-monitor"]
                    settingKey: "perMonitorWallpaper"
                    text: I18n.tr("Per-Monitor Wallpapers")
                    checked: SessionData.perMonitorWallpaper
                    onToggled: checked => SessionData.setPerMonitorWallpaper(checked)
                }

                SettingsToggleRow {
                    tab: "wallpaper"
                    tags: ["wallpaper", "light", "dark", "mode"]
                    settingKey: "perModeWallpaper"
                    text: I18n.tr("Light/Dark Wallpapers")
                    checked: SessionData.perModeWallpaper
                    onToggled: checked => SessionData.setPerModeWallpaper(checked)
                }

                SettingsToggleRow {
                    tab: "wallpaper"
                    tags: ["wallpaper", "cycling", "slideshow", "interval"]
                    settingKey: "wallpaperCyclingEnabled"
                    text: I18n.tr("Wallpaper Cycling")
                    checked: SessionData.wallpaperCyclingEnabled
                    onToggled: checked => SessionData.setWallpaperCyclingEnabled(checked)
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingM
                    visible: SessionData.wallpaperCyclingEnabled

                    VgsDropdown {
                        width: (parent.width - Theme.spacingM) / 2
                        dropdownWidth: width
                        currentValue: SessionData.wallpaperCyclingMode === "time" ? I18n.tr("At a fixed time") : I18n.tr("Every interval")
                        options: [I18n.tr("Every interval"), I18n.tr("At a fixed time")]
                        onValueChanged: value => SessionData.setWallpaperCyclingMode(value === I18n.tr("At a fixed time") ? "time" : "interval")
                    }

                    VgsDropdown {
                        width: (parent.width - Theme.spacingM) / 2
                        dropdownWidth: width
                        visible: SessionData.wallpaperCyclingMode !== "time"
                        currentValue: {
                            const options = root.cyclingIntervalOptions;
                            for (let i = 0; i < options.length; i++) {
                                if (options[i].value === SessionData.wallpaperCyclingInterval)
                                    return options[i].label;
                            }
                            return options[1].label;
                        }
                        options: root.cyclingIntervalOptions.map(o => o.label)
                        onValueChanged: value => {
                            const options = root.cyclingIntervalOptions;
                            for (let i = 0; i < options.length; i++) {
                                if (options[i].label === value) {
                                    SessionData.setWallpaperCyclingInterval(options[i].value);
                                    return;
                                }
                            }
                        }
                    }

                    VgsTextField {
                        width: (parent.width - Theme.spacingM) / 2
                        visible: SessionData.wallpaperCyclingMode === "time"
                        placeholderText: "06:00"
                        text: SessionData.wallpaperCyclingTime
                        backgroundColor: Theme.surfaceContainerHighest
                        onEditingFinished: {
                            if (/^\d{1,2}:\d{2}$/.test(text))
                                SessionData.setWallpaperCyclingTime(text);
                        }
                    }
                }
            }
        }
    }
}
