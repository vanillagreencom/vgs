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
    // How the `vshell theme icons --json` call this tab is waiting for ended: "pending"
    // while it runs, "failed" with the reason in loadError, "ok" once its list landed.
    property string readState: "pending"
    property string loadError: ""
    // The read this tab is waiting for. refresh() raises it at launch, so a reply from an
    // earlier read writes nothing: Proc lets same-id calls overlap once launched, and a
    // slower older reply would otherwise become the final state.
    property int readGeneration: 0

    readonly property bool followTheme: SettingsData.iconThemeDark === "System Default" && !SettingsData.iconThemePerMode

    readonly property string pickerState: iconPickerState(readState, followTheme, iconSets.length)
    // SettingsData.iconTheme is resolveIconTheme(), the one rule for which of the stored
    // names the shell is drawing, so a per-mode light session names its light set here.
    readonly property string appliedIcon: appliedSetName(readState, followTheme, themeIcon, SettingsData.iconTheme)
    readonly property string themeSet: themeSetName(readState, followTheme, themeIcon)
    readonly property string fixedTarget: fixedPickTarget(pickerState, SettingsData.iconTheme, iconSets)

    // BEGIN ICON PICKER MODEL
    // Keep this region free of root., Theme., I18n. and Qt. references: scripts/test-icon-picker.js extracts and executes it.

    // Why the picker draws no tiles. The tab draws one line of copy in their place for
    // each state that has something to say, so it never draws a control that does
    // nothing; "loading" says nothing, the read being too short to be worth reporting.
    // Nothing installed outranks the theme owning the choice: with no tile to apply,
    // the user needs the install advice whichever source is selected.
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

    // The set the shell draws, or "" when the card cannot establish which it is. Under
    // Follow theme the theme names it, and that name arrives with the set list.
    function appliedSetName(readState, followTheme, themeIcon, fixedIcon) {
        if (!followTheme)
            return fixedIcon;
        if (readState !== "ok")
            return "";
        return themeIcon || "System Default";
    }

    // The set the theme names, or "" when the card cannot state it. Under Follow theme
    // the applied line already names it, and the name arrives with the set list, so a
    // read that is not ok leaves the previous theme's name standing: the card states
    // nothing rather than the set a theme ago.
    function themeSetName(readState, followTheme, themeIcon) {
        if (followTheme || readState !== "ok")
            return "";
        return themeIcon;
    }

    // What the card may say about one icon set name, `sets` being the list a read
    // produced. Every SetLine asks this and asks nothing else.
    function iconSetClaim(readState, sets, name) {
        if (!name)
            return "absent";  // nothing to state, so the line is not drawn
        if (name === "System Default")
            return "default";  // the desktop's own set, which is not a set that can be missing
        if (readState !== "ok")
            return "unchecked";  // a named set with no list to check it against
        return sets.some(set => set.name === name) ? "installed" : "missing";
    }

    // The line a claim draws: its sentence, and whether it warns. `copy` carries the
    // translated `named` and `unnamed` sentences and the `notInstalled` suffix, each
    // named where it is supplied so no two can change places. Every SetLine's text,
    // warning and visibility read this answer, so a claim becomes words only here.
    function setLine(claim, copy) {
        if (claim === "absent")
            return { text: "", warn: false };
        if (claim === "default")
            return { text: copy.unnamed, warn: false };
        if (claim === "missing")
            return { text: copy.named + " — " + copy.notInstalled, warn: true };
        return { text: copy.named, warn: false };
    }

    // The set "Always use these" would apply: the one the user already owns when they own
    // one, otherwise the first of a list in hand, which only the two states carrying a
    // list have. Empty when neither is available, so that option has nothing to act on.
    function fixedPickTarget(pickerState, appliedIcon, sets) {
        if (appliedIcon && appliedIcon !== "System Default")
            return appliedIcon;
        if (pickerState !== "" && pickerState !== "follow-theme")
            return "";
        return (sets[0] || {}).name || "";
    }

    // Whether the Icon source row is drawn. Follow theme needs no list, so it acts
    // whenever the user is not already on it and stays reachable through a failed read.
    // Only where Follow theme is already selected and no set can be applied would
    // neither option change anything, and there the row is not drawn.
    function iconSourceRowShown(followTheme, fixedTarget) {
        return !followTheme || fixedTarget !== "";
    }
    // END ICON PICKER MODEL

    // One card line about an icon set. `label` carries a %1 for the set's name; every
    // other decision is the region's.
    component SetLine: StyledText {
        required property string label
        required property string setName
        readonly property var line: root.setLine(root.iconSetClaim(root.readState, root.iconSets, setName), { named: label.arg(setName), unnamed: label.arg(I18n.tr("the desktop's own icon set")), notInstalled: I18n.tr("not installed on this system.") })

        width: parent.width
        wrapMode: Text.WordWrap
        visible: line.text !== ""
        text: line.text
        color: line.warn ? Theme.warning : Theme.surfaceVariantText
        font.pixelSize: Theme.settingsFontSize
    }

    function refresh() {
        root.readGeneration += 1;
        const generation = root.readGeneration;
        // Nothing this read has not established may stand while it runs. Every card line
        // gates on readState, so raising it here withholds the previous read's names for
        // the whole of this one, the refresh a theme change triggers included.
        root.readState = "pending";
        Proc.runCommand("vgs-icons-list", [Paths.vshellCli, "theme", "icons", "--json"], function (output, exitCode, errorOutput) {
            // Settings destroys a tab when the user leaves its page, and Proc answers a
            // debounced call after that. A destroyed root reads as null here, and every
            // write below would raise on it; there is no longer a tab to report to.
            if (!root)
                return;
            // A reply from a read this tab has stopped waiting for publishes nothing.
            if (generation !== root.readGeneration)
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
                    visible: root.iconSourceRowShown(root.followTheme, root.fixedTarget)
                    text: I18n.tr("Icon source")
                    model: [I18n.tr("Follow theme"), I18n.tr("Always use these")]
                    currentIndex: root.followTheme ? 0 : 1
                    onSelectionChanged: (index, selected) => {
                        if (!selected)
                            return;
                        if (index === 0)
                            root.useFollowTheme();
                        else
                            root.useFixed(root.fixedTarget);
                    }
                }


                // What the shell draws now.
                SetLine {
                    label: I18n.tr("Currently applied: %1")
                    setName: root.appliedIcon
                }

                // What the theme would pick, while the user's own choice overrides it.
                SetLine {
                    label: I18n.tr("This theme's icon set: %1")
                    setName: root.themeSet
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
                        model: root.iconSets

                        IconSetTile {
                            required property var modelData
                            setName: modelData.name
                            samples: modelData.samples
                            applied: modelData.name === root.appliedIcon
                            onActivated: root.useFixed(modelData.name)
                        }
                    }
                }
            }
        }
    }
}
