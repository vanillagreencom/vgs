import QtCore
import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets
import "../../Common/ConfigIncludeResolve.js" as ConfigIncludeResolve

Item {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property var layoutIncludeStatus: ({
            "exists": false,
            "included": false,
            "configFormat": "",
            "readOnly": false
        })
    readonly property bool readOnly: CompositorService.isHyprland && layoutIncludeStatus.readOnly === true
    property bool checkingInclude: false
    property bool fixingInclude: false
    property string xrayConflictSource: ""

    function getLayoutConfigPaths() {
        const configDir = Paths.strip(StandardPaths.writableLocation(StandardPaths.ConfigLocation));
        switch (CompositorService.compositor) {
        case "niri":
            return {
                "configFile": configDir + "/niri/config.kdl",
                "layoutFile": configDir + "/niri/vgs/layout.kdl",
                "grepPattern": 'include.*"vgs/layout.kdl"',
                "includeLine": 'include "vgs/layout.kdl"'
            };
        case "hyprland":
            return {
                "configFile": configDir + "/hypr/hyprland.lua",
                "layoutFile": configDir + "/hypr/vgs/layout.lua",
                "grepPattern": "vgs.layout",
                "includeLine": "require(\"vgs.layout\")"
            };
        case "mango":
            return {
                "configFile": configDir + "/mango/config.conf",
                "layoutFile": configDir + "/mango/vgs/layout.conf",
                "grepPattern": "source.*vgs/layout.conf",
                "includeLine": "source=./vgs/layout.conf"
            };
        default:
            return null;
        }
    }

    function checkLayoutIncludeStatus() {
        const compositor = CompositorService.compositor;
        if (compositor !== "niri" && compositor !== "hyprland" && compositor !== "mango") {
            layoutIncludeStatus = {
                "exists": false,
                "included": false,
                "configFormat": "",
                "readOnly": false
            };
            return;
        }

        const filename = compositor === "niri" ? "layout.kdl" : (compositor === "hyprland" ? "layout.lua" : "layout.conf");
        const compositorArg = compositor === "mango" ? "mangowc" : compositor;

        checkingInclude = true;
        Proc.runCommand("check-layout-include", [Paths.vshellCli, "config", "resolve-include", compositorArg, filename], (output, exitCode) => {
            checkingInclude = false;
            if (exitCode !== 0) {
                layoutIncludeStatus = {
                    "exists": false,
                    "included": false,
                    "configFormat": "",
                    "readOnly": false
                };
                return;
            }
            try {
                layoutIncludeStatus = JSON.parse(output.trim());
            } catch (e) {
                layoutIncludeStatus = {
                    "exists": false,
                    "included": false,
                    "configFormat": "",
                    "readOnly": false
                };
            }
        });
    }

    function fixLayoutInclude() {
        if (readOnly) {
            ToastService.showWarning(I18n.tr("Hyprland edits are read-only"), layoutIncludeStatus.statusMessage || I18n.tr("VGS can't edit Hyprland layout settings from Settings; edit your Hyprland config directly."), "", "hyprland-migration");
            return;
        }
        const paths = getLayoutConfigPaths();
        if (!paths)
            return;

        fixingInclude = true;
        if (CompositorService.isNiri) {
            Proc.runCommand("fix-layout-include", [
                Paths.vshellCli,
                "config",
                "repair-include",
                "niri",
                "layout.kdl",
                "--json"
            ], (output, exitCode) => {
                fixingInclude = false;
                if (exitCode !== 0)
                    return;
                checkLayoutIncludeStatus();
                SettingsData.updateCompositorLayout();
            });
            return;
        }
        const unixTime = Math.floor(Date.now() / 1000);
        const backupFile = paths.configFile + ".backup" + unixTime;
        const script = ConfigIncludeResolve.buildRepairScript({
            configFile: paths.configFile,
            backupFile: backupFile,
            fragmentFile: paths.layoutFile,
            grepPattern: paths.grepPattern,
            includeLine: paths.includeLine
        });
        Proc.runCommand("fix-layout-include", ["sh", "-c", script], (output, exitCode) => {
            fixingInclude = false;
            if (exitCode !== 0)
                return;
            checkLayoutIncludeStatus();
            SettingsData.updateCompositorLayout();
        });
    }

    function checkXrayConflicts() {
        // Niri exposes no compositor blur in VGS, so there is no xray state
        // to reconcile with external configuration.
        xrayConflictSource = "";
    }

    Component.onCompleted: {
        if (CompositorService.isNiri || CompositorService.isHyprland || CompositorService.isMango) {
            checkLayoutIncludeStatus();
            checkXrayConflicts();
        }
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: layoutColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: layoutColumn

            topPadding: Theme.spacingXS
            width: Math.min(550, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingL

            StyledRect {
                id: warningBox
                width: parent.width
                height: warningContent.implicitHeight + Theme.spacingL * 2
                radius: Theme.cornerRadius

                readonly property bool showLegacy: root.readOnly
                readonly property bool showSetup: !showLegacy && !root.layoutIncludeStatus.included

                color: (showLegacy || showSetup) ? Theme.withAlpha(Theme.primary, 0.15) : Theme.withAlpha(Theme.primary, 0)
                border.color: (showLegacy || showSetup) ? Theme.withAlpha(Theme.primary, 0.3) : Theme.withAlpha(Theme.primary, 0)
                border.width: 1
                visible: (showLegacy || showSetup) && !root.checkingInclude && (CompositorService.isNiri || CompositorService.isHyprland || CompositorService.isMango)

                Row {
                    id: warningContent
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    VgsIcon {
                        name: "warning"
                        size: Theme.iconSize
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        width: parent.width - Theme.iconSize - (fixButton.visible ? fixButton.width + Theme.spacingM : 0) - Theme.spacingM
                        spacing: Theme.spacingXS
                        anchors.verticalCenter: parent.verticalCenter

                        StyledText {
                            text: {
                                if (warningBox.showLegacy)
                                    return I18n.tr("Hyprland edits are read-only");
                                if (warningBox.showSetup)
                                    return I18n.tr("First Time Setup");
                                return "";
                            }
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.primary
                            width: parent.width
                            horizontalAlignment: Text.AlignLeft
                        }

                        StyledText {
                            text: {
                                if (warningBox.showLegacy)
                                    return root.layoutIncludeStatus.statusMessage || I18n.tr("VGS can't edit Hyprland layout settings from Settings; edit your Hyprland config directly.");
                                if (warningBox.showSetup)
                                    return I18n.tr("Click Setup to create %1 and add the include to your compositor config").arg("vgs/layout");
                                return "";
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                            width: parent.width
                            horizontalAlignment: Text.AlignLeft
                        }
                    }

                    VgsButton {
                        id: fixButton
                        visible: !warningBox.showLegacy && warningBox.showSetup
                        text: root.fixingInclude ? I18n.tr("Setting up...") : I18n.tr("Setup")
                        backgroundColor: Theme.primary
                        textColor: Theme.primaryText
                        enabled: !root.fixingInclude
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: root.fixLayoutInclude()
                    }
                }
            }

            StyledRect {
                width: parent.width
                height: xrayConflictRow.implicitHeight + Theme.spacingL * 2
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.primary, 0.15)
                border.color: Theme.withAlpha(Theme.primary, 0.3)
                border.width: 1
                visible: root.xrayConflictSource !== ""

                Row {
                    id: xrayConflictRow
                    anchors.fill: parent
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingM

                    VgsIcon {
                        name: "warning"
                        size: Theme.iconSize
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        width: parent.width - Theme.iconSize - Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("An xray rule at %1 may conflict with the Xray settings below").arg(root.xrayConflictSource)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                }
            }

            SettingsCard {
                width: parent.width
                tags: ["niri", "layout", "gaps", "radius", "window", "border"]
                title: I18n.tr("Niri Layout")
                settingKey: "niriLayout"
                iconName: "layers"
                visible: CompositorService.isNiri

                SettingsChoiceRow {
                    tags: ["niri", "gaps", "override", "unmanaged"]
                    settingKey: "niriLayoutGapsMode"
                    text: I18n.tr("Gaps")
                    description: I18n.tr("Auto matches bar spacing; Off leaves gaps to your niri config")
                    model: [I18n.tr("Auto"), I18n.tr("Custom"), I18n.tr("Off")]
                    currentIndex: {
                        if (SettingsData.niriLayoutGapsOverride === -2)
                            return 2;
                        return SettingsData.niriLayoutGapsOverride >= 0 ? 1 : 0;
                    }
                    onSelectionChanged: (index, selected) => {
                        if (!selected)
                            return;
                        switch (index) {
                        case 1:
                            SettingsData.set("niriLayoutGapsOverride", Math.max(4, (SettingsData.barConfigs[0]?.spacing ?? 4)));
                            return;
                        case 2:
                            SettingsData.set("niriLayoutGapsOverride", -2);
                            return;
                        default:
                            SettingsData.set("niriLayoutGapsOverride", -1);
                        }
                    }
                }

                SettingsSliderRow {
                    tags: ["niri", "gaps", "override"]
                    settingKey: "niriLayoutGapsOverride"
                    text: I18n.tr("Window Gaps")
                    description: I18n.tr("Space between windows")
                    visible: SettingsData.niriLayoutGapsOverride >= 0
                    value: Math.max(0, SettingsData.niriLayoutGapsOverride)
                    minimum: 0
                    maximum: 50
                    unit: "px"
                    defaultValue: Math.max(4, (SettingsData.barConfigs[0]?.spacing ?? 4))
                    onSliderValueChanged: newValue => SettingsData.set("niriLayoutGapsOverride", newValue)
                }

                SettingsToggleRow {
                    visible: false
                    tags: ["niri", "xray", "blur", "background-effect", "performance"]
                    settingKey: "niriLayoutXrayEnabled"
                    text: I18n.tr("Xray Blur Effect")
                    description: I18n.tr("Blurred surfaces show the wallpaper instead of the content beneath")
                    checked: NiriService.layoutXrayEnabled
                    onToggled: checked => NiriService.setLayoutXray(checked)
                }

                SettingsToggleRow {
                    visible: false
                    tags: ["niri", "xray", "bar", "performance"]
                    settingKey: "niriLayoutBarXrayEnabled"
                    text: I18n.tr("VGS Bar Xray")
                    description: I18n.tr("Always blur against the wallpaper, even with Xray off")
                    checked: NiriService.layoutBarXrayEnabled
                    onToggled: checked => NiriService.setLayoutBarXray(checked)
                }
            }

            SettingsCard {
                width: parent.width
                tags: ["hyprland", "layout", "gaps", "window"]
                title: I18n.tr("Hyprland Layout")
                settingKey: "hyprlandLayout"
                iconName: "crop_square"
                visible: CompositorService.isHyprland

                SettingsChoiceRow {
                    tags: ["hyprland", "gaps", "override", "inner", "outer", "unmanaged"]
                    settingKey: "hyprlandLayoutGapsMode"
                    text: I18n.tr("Gaps")
                    description: I18n.tr("Config leaves gaps to your Hyprland config; Custom writes VGS gap values")
                    model: [I18n.tr("Config"), I18n.tr("Custom"), I18n.tr("Off")]
                    currentIndex: {
                        if (SettingsData.hyprlandLayoutGapsOverride === -2)
                            return 2;
                        return SettingsData.hyprlandLayoutGapsOverride >= 0 ? 1 : 0;
                    }
                    onSelectionChanged: (index, selected) => {
                        if (!selected)
                            return;
                        switch (index) {
                        case 1:
                            SettingsData.set("hyprlandLayoutGapsOverride", Math.max(4, (SettingsData.barConfigs[0]?.spacing ?? 4)));
                            return;
                        case 2:
                            SettingsData.set("hyprlandLayoutGapsOverride", -2);
                            return;
                        default:
                            SettingsData.set("hyprlandLayoutGapsOverride", -1);
                        }
                    }
                }

                SettingsSliderRow {
                    tags: ["hyprland", "gaps", "override", "inner"]
                    settingKey: "hyprlandLayoutGapsOverride"
                    text: I18n.tr("Inner Gaps")
                    description: I18n.tr("Space between windows") + " (gaps_in)"
                    visible: SettingsData.hyprlandLayoutGapsOverride >= 0
                    value: Math.max(0, SettingsData.hyprlandLayoutGapsOverride)
                    minimum: 0
                    maximum: 50
                    unit: "px"
                    defaultValue: Math.max(4, (SettingsData.barConfigs[0]?.spacing ?? 4))
                    onSliderValueChanged: newValue => SettingsData.set("hyprlandLayoutGapsOverride", newValue)
                }

                SettingsSliderRow {
                    tags: ["hyprland", "gaps", "override", "outer", "edge"]
                    settingKey: "hyprlandLayoutGapsOutOverride"
                    text: I18n.tr("Outer Gaps")
                    description: I18n.tr("Space between windows and screen edges") + " (gaps_out)"
                    visible: SettingsData.hyprlandLayoutGapsOverride >= 0
                    value: SettingsData.hyprlandLayoutGapsOutOverride >= 0 ? SettingsData.hyprlandLayoutGapsOutOverride : Math.max(0, SettingsData.hyprlandLayoutGapsOverride)
                    minimum: 0
                    maximum: 50
                    unit: "px"
                    defaultValue: Math.max(0, SettingsData.hyprlandLayoutGapsOverride)
                    onSliderValueChanged: newValue => SettingsData.set("hyprlandLayoutGapsOutOverride", newValue)
                }

                SettingsToggleRow {
                    tags: ["hyprland", "resize", "border", "mouse", "drag"]
                    settingKey: "hyprlandResizeOnBorder"
                    text: I18n.tr("Resize on Border")
                    description: I18n.tr("Resize windows by dragging their edges with the mouse")
                    checked: SettingsData.hyprlandResizeOnBorder
                    onToggled: checked => SettingsData.set("hyprlandResizeOnBorder", checked)
                }

                SettingsToggleRow {
                    visible: CompositorService.isHyprland
                    tags: ["hyprland", "xray", "blur", "background-effect", "performance"]
                    settingKey: "hyprlandLayoutXrayEnabled"
                    text: I18n.tr("Xray Blur Effect")
                    description: I18n.tr("Blurred surfaces show the wallpaper instead of the content beneath")
                    checked: HyprlandService.layoutXrayEnabled
                    onToggled: checked => HyprlandService.setLayoutXray(checked)
                }

                SettingsToggleRow {
                    visible: CompositorService.isHyprland
                    tags: ["hyprland", "xray", "bar", "performance"]
                    settingKey: "hyprlandLayoutBarXrayEnabled"
                    text: I18n.tr("VGS Bar Xray")
                    description: I18n.tr("Always blur against the wallpaper, even with Xray off")
                    checked: HyprlandService.layoutBarXrayEnabled
                    onToggled: checked => HyprlandService.setLayoutBarXray(checked)
                }
            }

            SettingsCard {
                width: parent.width
                tags: ["mangowc", "mango", "dwl", "layout", "gaps", "radius", "window", "border"]
                title: I18n.tr("MangoWC Layout")
                settingKey: "mangoLayout"
                iconName: "crop_square"
                visible: CompositorService.isMango

                SettingsChoiceRow {
                    tags: ["mangowc", "mango", "gaps", "override", "inner", "outer", "unmanaged"]
                    settingKey: "mangoLayoutGapsMode"
                    text: I18n.tr("Gaps")
                    description: I18n.tr("Auto matches bar spacing; Off leaves gaps to your MangoWC config")
                    model: [I18n.tr("Auto"), I18n.tr("Custom"), I18n.tr("Off")]
                    currentIndex: {
                        if (SettingsData.mangoLayoutGapsOverride === -2)
                            return 2;
                        return SettingsData.mangoLayoutGapsOverride >= 0 ? 1 : 0;
                    }
                    onSelectionChanged: (index, selected) => {
                        if (!selected)
                            return;
                        switch (index) {
                        case 1:
                            SettingsData.set("mangoLayoutGapsOverride", Math.max(4, (SettingsData.barConfigs[0]?.spacing ?? 4)));
                            return;
                        case 2:
                            SettingsData.set("mangoLayoutGapsOverride", -2);
                            return;
                        default:
                            SettingsData.set("mangoLayoutGapsOverride", -1);
                        }
                    }
                }

                SettingsSliderRow {
                    tags: ["mangowc", "mango", "gaps", "override", "inner"]
                    settingKey: "mangoLayoutGapsOverride"
                    text: I18n.tr("Inner Gaps")
                    description: I18n.tr("Space between windows") + " (gappih/gappiv)"
                    visible: SettingsData.mangoLayoutGapsOverride >= 0
                    value: Math.max(0, SettingsData.mangoLayoutGapsOverride)
                    minimum: 0
                    maximum: 50
                    unit: "px"
                    defaultValue: Math.max(4, (SettingsData.barConfigs[0]?.spacing ?? 4))
                    onSliderValueChanged: newValue => SettingsData.set("mangoLayoutGapsOverride", newValue)
                }

                SettingsSliderRow {
                    tags: ["mangowc", "mango", "gaps", "override", "outer", "edge"]
                    settingKey: "mangoLayoutGapsOutOverride"
                    text: I18n.tr("Outer Gaps")
                    description: I18n.tr("Space between windows and screen edges") + " (gappoh/gappov)"
                    visible: SettingsData.mangoLayoutGapsOverride >= 0
                    value: SettingsData.mangoLayoutGapsOutOverride >= 0 ? SettingsData.mangoLayoutGapsOutOverride : Math.max(0, SettingsData.mangoLayoutGapsOverride)
                    minimum: 0
                    maximum: 50
                    unit: "px"
                    defaultValue: Math.max(0, SettingsData.mangoLayoutGapsOverride)
                    onSliderValueChanged: newValue => SettingsData.set("mangoLayoutGapsOutOverride", newValue)
                }

                SettingsToggleRow {
                    tags: ["mangowc", "mango", "radius", "override"]
                    settingKey: "mangoLayoutRadiusOverrideEnabled"
                    text: I18n.tr("Manage Window Radius")
                    description: I18n.tr("Control compositor window radius from VGS settings")
                    checked: SettingsData.mangoLayoutRadiusOverride >= 0
                    onToggled: checked => {
                        if (checked) {
                            SettingsData.set("mangoLayoutRadiusOverride", SettingsData.cornerRadius);
                            return;
                        }
                        SettingsData.set("mangoLayoutRadiusOverride", -1);
                    }
                }

                SettingsSliderRow {
                    tags: ["mangowc", "mango", "radius", "override"]
                    settingKey: "mangoLayoutRadiusOverride"
                    text: I18n.tr("Window Corner Radius")
                    description: I18n.tr("Rounded corners for windows") + " (border_radius)"
                    visible: SettingsData.mangoLayoutRadiusOverride >= 0
                    value: Math.max(0, SettingsData.mangoLayoutRadiusOverride)
                    minimum: 0
                    maximum: 100
                    unit: "px"
                    defaultValue: SettingsData.cornerRadius
                    onSliderValueChanged: newValue => SettingsData.set("mangoLayoutRadiusOverride", newValue)
                }

                SettingsToggleRow {
                    tags: ["mangowc", "mango", "border", "override"]
                    settingKey: "mangoLayoutBorderSizeEnabled"
                    text: I18n.tr("Manage Border Size")
                    description: I18n.tr("Control compositor border width from VGS settings")
                    checked: SettingsData.mangoLayoutBorderSize >= 0
                    onToggled: checked => {
                        if (checked) {
                            SettingsData.set("mangoLayoutBorderSize", 2);
                            return;
                        }
                        SettingsData.set("mangoLayoutBorderSize", -1);
                    }
                }

                SettingsSliderRow {
                    tags: ["mangowc", "mango", "border", "override"]
                    settingKey: "mangoLayoutBorderSize"
                    text: I18n.tr("Border Size")
                    description: I18n.tr("Width of window border") + " (borderpx)"
                    visible: SettingsData.mangoLayoutBorderSize >= 0
                    value: Math.max(0, SettingsData.mangoLayoutBorderSize)
                    minimum: 0
                    maximum: 10
                    unit: "px"
                    defaultValue: 2
                    onSliderValueChanged: newValue => SettingsData.set("mangoLayoutBorderSize", newValue)
                }
            }
        }
    }
}
