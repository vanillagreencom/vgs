pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root
    property var parentModal: null

    // Icon aspect state (helper-provided): installed sets + the theme's named set.
    property var installedThemes: []
    property string themeIcon: ""
    property bool themeIconInstalled: false

    readonly property bool followTheme: SettingsData.iconThemeDark === "System Default" && !SettingsData.iconThemePerMode
    readonly property string effectiveIcon: followTheme ? (themeIcon || "System Default") : SettingsData.iconThemeDark

    function refresh() {
        Proc.runCommand("vgs-icons-list", [Paths.vshellCli, "theme", "icons", "--json"], function (output, exitCode) {
            if (exitCode !== 0)
                return;
            try {
                const data = JSON.parse(output || "{}");
                root.installedThemes = data.installed || [];
                root.themeIcon = data.themeIcon || "";
                root.themeIconInstalled = data.themeIconInstalled === true;
            } catch (e) {
                // leave prior state on parse failure
            }
        });
    }

    function useFollowTheme() {
        SettingsData.setIconThemeUnmanaged();
        // Re-run the theme's icon hook so the theme's set is applied now.
        if (VGSThemeService.currentTheme.name)
            VGSThemeService.applyBlueprint(VGSThemeService.currentTheme.name);
        refresh();
    }

    function useFixed(name) {
        if (!name)
            return;
        SettingsData.set("iconThemePerMode", false);
        SettingsData.set("iconThemeDark", name);
        SettingsData.set("iconThemeLight", name);
        SettingsData.saveSettings();
        SettingsData.applyStoredIconTheme();
        refresh();
    }

    Component.onCompleted: refresh()

    Connections {
        target: VGSThemeService
        function onCurrentLoaded() {
            root.refresh();
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

            ThemeSubNav {
                width: parent.width
                parentModal: root.parentModal
                activeId: "icons"
            }

            SettingsCard {
                title: I18n.tr("Icon Theme")
                iconName: "interests"
                settingKey: "iconAspect"
                width: parent.width

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: I18n.tr("Choose whether app icons follow the active theme or always use a set you pick.")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                SettingsChoiceRow {
                    text: I18n.tr("Icon source")
                    model: [I18n.tr("Follow theme"), I18n.tr("Always use these")]
                    currentIndex: root.followTheme ? 0 : 1
                    onSelectionChanged: (index, selected) => {
                        if (!selected)
                            return;
                        if (index === 0)
                            root.useFollowTheme();
                        else if (root.installedThemes.length > 0)
                            root.useFixed(SettingsData.iconThemeDark !== "System Default" ? SettingsData.iconThemeDark : root.installedThemes[0]);
                    }
                }

                // Theme's named set + install status
                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    visible: root.themeIcon !== ""
                    text: {
                        const base = I18n.tr("This theme's icon set: %1").arg(root.themeIcon);
                        if (!root.themeIconInstalled)
                            return base + " — " + I18n.tr("not installed on this system, so icons stay unchanged. Install it or pick a set below.");
                        return base;
                    }
                    color: root.themeIcon !== "" && !root.themeIconInstalled ? Theme.warning : Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                // Installed-theme picker (active when not following the theme)
                SettingsDropdownRow {
                    width: parent.width
                    text: I18n.tr("Icon set")
                    description: I18n.tr("Applied when \"Always use these\" is selected")
                    enabled: !root.followTheme && root.installedThemes.length > 0
                    currentValue: SettingsData.iconThemeDark
                    options: root.installedThemes
                    onValueChanged: value => root.useFixed(value)
                }

                StyledText {
                    width: parent.width
                    visible: root.installedThemes.length === 0
                    wrapMode: Text.WordWrap
                    text: I18n.tr("No additional icon themes found in /usr/share/icons or ~/.local/share/icons. Install one (e.g. Papirus or the Yaru color set) to switch icons.")
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }

                StyledText {
                    width: parent.width
                    text: I18n.tr("Currently applied: %1").arg(root.effectiveIcon)
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                }
            }
        }
    }
}
