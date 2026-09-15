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
    // How the last `vshell theme icons --json` call ended: "pending" before its first
    // reply, "failed" with the reason in loadError, "ok" once a list landed.
    property string readState: "pending"
    property string loadError: ""

    readonly property bool followTheme: SettingsData.iconThemeDark === "System Default" && !SettingsData.iconThemePerMode
    readonly property string effectiveIcon: followTheme ? (themeIcon || "System Default") : SettingsData.iconThemeDark

    readonly property var tiles: iconSetTiles(iconSets)
    readonly property string pickerState: iconPickerState(readState, followTheme, tiles.length)
    readonly property string appliedState: appliedSetState(readState, tiles, effectiveIcon)

    // BEGIN ICON PICKER MODEL
    // Keep this region free of root., Theme., I18n. and Qt. references: scripts/test-icon-picker.js extracts and executes it.

    // One tile per installed icon set. `sets` is the `sets` list of
    // `vshell theme icons --json`: a name and the absolute paths of the sample icons
    // the helper resolved through that set's own inherit chain. The delegate marks the
    // applied set, so picking one moves the mark without rebuilding the tiles.
    function iconSetTiles(sets) {
        return (sets || []).filter(set => !!set.name).map(set => ({
                    name: set.name,
                    samples: (set.samples || []).filter(path => !!path)
                }));
    }

    // Why the picker draws no tiles: "loading" before the set list has been read,
    // "error" when reading it failed, "empty" when it was read and holds none,
    // "follow-theme" while the active theme owns the choice, "" when the tiles are
    // drawn. The tab replaces the tiles with one line of copy for each state that has
    // something to say, so it never draws a control that does nothing and never reports
    // an installed set as absent because the list is not in hand. Nothing installed
    // outranks the theme owning the choice: with no tile to apply, the user needs the
    // install advice whichever source is selected.
    function iconPickerState(readState, followTheme, tileCount) {
        if (readState === "pending")
            return "loading";
        if (readState === "failed")
            return "error";
        if (tileCount === 0)
            return "empty";
        if (followTheme)
            return "follow-theme";
        return "";
    }

    // What is known about the set the shell draws now: "missing" when the set list was
    // read and does not carry it, "applied" when the list carries it, "unknown" while
    // there is no list. Without a list, the tab states the set and claims nothing about
    // whether it is installed.
    function appliedSetState(readState, tiles, applied) {
        if (readState !== "ok")
            return "unknown";
        return tiles.some(tile => tile.name === applied) ? "applied" : "missing";
    }
    // END ICON PICKER MODEL

    function refresh() {
        Proc.runCommand("vgs-icons-list", [Paths.vshellCli, "theme", "icons", "--json"], function (output, exitCode, errorOutput) {
            // Settings destroys a tab when the user leaves its page, and Proc answers a
            // debounced call after that. A destroyed root reads as null here, and every
            // write below would raise on it; there is no longer a tab to report to.
            if (!root)
                return;
            if (exitCode !== 0) {
                const detail = (errorOutput || output || I18n.tr("Helper exited with code %1").arg(exitCode)).trim();
                Log.scoped("IconsTab").warn("Failed to read the installed icon sets:", detail);
                root.loadError = detail;
                root.readState = "failed";
                return;
            }
            try {
                const data = JSON.parse(output || "{}");
                root.iconSets = data.sets || [];
                root.themeIcon = data.themeIcon || "";
                root.themeIconInstalled = data.themeIconInstalled === true;
                root.loadError = "";
                root.readState = "ok";
            } catch (e) {
                Log.scoped("IconsTab").warn("Unreadable icon set list:", e);
                root.loadError = String(e);
                root.readState = "failed";
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


                // What the shell draws now. Visible in every state, so a failed helper
                // call and a set that is no longer installed both still name it.
                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: {
                        const base = I18n.tr("Currently applied: %1").arg(root.effectiveIcon);
                        if (root.appliedState === "missing")
                            return base + " — " + I18n.tr("not installed on this system, so icons stay unchanged.");
                        return base;
                    }
                    color: root.appliedState === "missing" ? Theme.warning : Theme.surfaceVariantText
                    font.pixelSize: Theme.settingsFontSize
                }

                // What the theme would pick, while the user's own choice overrides it.
                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    visible: root.themeIcon !== "" && !root.followTheme
                    text: {
                        const base = I18n.tr("This theme's icon set: %1").arg(root.themeIcon);
                        if (!root.themeIconInstalled)
                            return base + " — " + I18n.tr("not installed on this system.");
                        return base;
                    }
                    color: !root.themeIconInstalled ? Theme.warning : Theme.surfaceVariantText
                    font.pixelSize: Theme.settingsFontSize
                }

                // The picker's stand-in: one line saying why there is nothing to pick.
                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    visible: text !== ""
                    text: {
                        if (root.pickerState === "error")
                            return I18n.tr("Could not read the installed icon sets: %1").arg(root.loadError);
                        if (root.pickerState === "empty")
                            return I18n.tr("No icon sets are installed, so there is nothing to pick. Install an icon set to switch icons.");
                        if (root.pickerState === "follow-theme")
                            return I18n.tr("The active theme picks the icon set. Choose \"Always use these\" to pick a set yourself.");
                        return "";
                    }
                    color: root.pickerState === "error" ? Theme.warning : Theme.surfaceVariantText
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
                            applied: modelData.name === root.effectiveIcon
                            onActivated: root.useFixed(modelData.name)
                        }
                    }
                }
            }
        }
    }
}
