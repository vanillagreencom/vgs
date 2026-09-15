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

    // Icon aspect state (helper-provided): installed sets with their sample icons,
    // plus the theme's named set.
    property var iconSets: []
    property string themeIcon: ""
    property bool themeIconInstalled: false

    readonly property bool followTheme: SettingsData.iconThemeDark === "System Default" && !SettingsData.iconThemePerMode
    readonly property string effectiveIcon: followTheme ? (themeIcon || "System Default") : SettingsData.iconThemeDark

    readonly property var tiles: iconSetTiles(iconSets, effectiveIcon)
    readonly property string pickerState: iconPickerState(followTheme, tiles.length)

    // BEGIN ICON PICKER MODEL
    // Keep this region free of root., Theme., I18n. and Qt. references: scripts/test-icon-picker.js extracts and executes it.

    // One tile per installed icon set. `sets` is the `sets` list of
    // `vshell theme icons --json`: a name and the absolute paths of the sample icons
    // the helper resolved through that set's own inherit chain. `applied` is the set
    // the shell draws now, which marks its tile.
    function iconSetTiles(sets, applied) {
        return (sets || []).filter(set => !!set.name).map(set => ({
                    name: set.name,
                    samples: (set.samples || []).filter(path => !!path),
                    applied: set.name === applied
                }));
    }

    // Why the picker draws no tiles: "follow-theme" while the active theme owns the
    // icon set, "empty" when no set is installed, "" when the tiles are drawn. The tab
    // replaces the tiles with one line of copy for each non-empty state, so it never
    // draws a control that does nothing.
    function iconPickerState(followTheme, tileCount) {
        if (followTheme)
            return "follow-theme";
        if (tileCount === 0)
            return "empty";
        return "";
    }
    // END ICON PICKER MODEL

    function refresh() {
        Proc.runCommand("vgs-icons-list", [Paths.vshellCli, "theme", "icons", "--json"], function (output, exitCode) {
            if (exitCode !== 0)
                return;
            try {
                const data = JSON.parse(output || "{}");
                root.iconSets = data.sets || [];
                root.themeIcon = data.themeIcon || "";
                root.themeIconInstalled = data.themeIconInstalled === true;
            } catch (e) {

            }
        });
    }

    function useFollowTheme() {
        SettingsData.setIconThemeUnmanaged();

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
                    font.pixelSize: Theme.settingsFontSize
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
                        else if (root.tiles.length > 0)
                            root.useFixed(SettingsData.iconThemeDark !== "System Default" ? SettingsData.iconThemeDark : root.tiles[0].name);
                    }
                }


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
                    font.pixelSize: Theme.settingsFontSize
                }

                // The picker's stand-in: one line saying why there is nothing to pick,
                // and, while the theme owns the choice, what the shell draws instead.
                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    visible: root.pickerState !== ""
                    text: {
                        if (root.pickerState === "follow-theme")
                            return I18n.tr("The active theme picks the icon set. Currently applied: %1. Choose \"Always use these\" to pick a set yourself.").arg(root.effectiveIcon);
                        return I18n.tr("No icon sets are installed, so there is nothing to pick. Install an icon set to switch icons.");
                    }
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.settingsFontSize
                }

                Flow {
                    width: parent.width
                    visible: root.pickerState === ""
                    spacing: Theme.spacingS

                    Repeater {
                        model: root.tiles

                        IconSetTile {
                            required property var modelData
                            setName: modelData.name
                            samples: modelData.samples
                            applied: modelData.applied
                            onActivated: root.useFixed(modelData.name)
                        }
                    }
                }
            }
        }
    }
}
