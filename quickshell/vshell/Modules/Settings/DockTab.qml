import QtQuick
import qs.Common
import qs.Modals.FileBrowser
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root

    property var parentModal: null
    FileBrowserModal {
        id: dockLogoFileBrowser
        browserTitle: I18n.tr("Select Dock Launcher Logo")
        browserType: "generic"
        filterExtensions: ["*.svg", "*.png", "*.jpg", "*.jpeg", "*.webp"]
        onFileSelected: path => SettingsData.set("dockLauncherLogoCustomPath", path.replace("file://", ""))
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn
            topPadding: Theme.spacingXS
            width: Math.min(550, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            SettingsCard {
                width: parent.width
                iconName: "dock_to_bottom"
                title: I18n.tr("Dock Visibility")
                settingKey: "dockVisibility"

                SettingsToggleRow {
                    settingKey: "showDock"
                    tags: ["dock", "show", "display", "enable"]
                    text: I18n.tr("Show Dock")
                    description: I18n.tr("Display a dock with pinned and running applications")
                    checked: SettingsData.showDock
                    onToggled: checked => SettingsData.setShowDock(checked)
                }

                SettingsToggleRow {
                    settingKey: "dockAutoHide"
                    tags: ["dock", "autohide", "hide", "hover"]
                    text: I18n.tr("Auto-hide Dock")
                    description: I18n.tr("Keep the dock hidden and reveal it when hovering near its edge")
                    checked: SettingsData.dockAutoHide
                    visible: SettingsData.showDock
                    onToggled: checked => {
                        if (checked && SettingsData.dockSmartAutoHide) {
                            SettingsData.set("dockSmartAutoHide", false);
                        }
                        SettingsData.set("dockAutoHide", checked);
                    }
                }

                SettingsToggleRow {
                    settingKey: "dockSmartAutoHide"
                    tags: ["dock", "smart", "autohide", "windows", "overlap", "intelligent"]
                    text: I18n.tr("Intelligent Auto-hide")
                    description: I18n.tr("Show dock when floating windows don't overlap its area")
                    checked: SettingsData.dockSmartAutoHide
                    visible: SettingsData.showDock && (CompositorService.isNiri || CompositorService.isHyprland || CompositorService.isMango)
                    onToggled: checked => {
                        if (checked && SettingsData.dockAutoHide) {
                            SettingsData.set("dockAutoHide", false);
                        }
                        SettingsData.set("dockSmartAutoHide", checked);
                    }
                }

                SettingsToggleRow {
                    settingKey: "dockOpenOnOverview"
                    tags: ["dock", "overview", "niri"]
                    text: I18n.tr("Show on Overview")
                    description: I18n.tr("Always show the dock when niri's overview is open")
                    checked: SettingsData.dockOpenOnOverview
                    visible: CompositorService.isNiri
                    onToggled: checked => SettingsData.set("dockOpenOnOverview", checked)
                }

                SettingsToggleRow {
                    settingKey: "dockUseOverlayLayer"
                    tags: ["dock", "fullscreen", "overlay", "layer"]
                    text: I18n.tr("Use Overlay Layer", "dock layer toggle: use Wayland overlay layer")
                    description: I18n.tr("Place the dock on the Wayland overlay layer")
                    checked: SettingsData.dockUseOverlayLayer
                    visible: SettingsData.showDock
                    onToggled: checked => SettingsData.set("dockUseOverlayLayer", checked)
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "swap_vert"
                title: I18n.tr("Position")
                settingKey: "dockPosition"

                SettingsChoiceRow {
                    tags: ["dock", "position", "edge", "top", "bottom", "left", "right"]
                    text: I18n.tr("Screen Edge")
                    model: [I18n.tr("Top"), I18n.tr("Bottom"), I18n.tr("Left"), I18n.tr("Right")]
                    currentIndex: {
                        switch (SettingsData.dockPosition) {
                        case SettingsData.Position.Top:
                            return 0;
                        case SettingsData.Position.Bottom:
                            return 1;
                        case SettingsData.Position.Left:
                            return 2;
                        case SettingsData.Position.Right:
                            return 3;
                        default:
                            return 1;
                        }
                    }
                    onSelectionChanged: (index, selected) => {
                        if (!selected)
                            return;
                        switch (index) {
                        case 0:
                            SettingsData.setDockPosition(SettingsData.Position.Top);
                            break;
                        case 1:
                            SettingsData.setDockPosition(SettingsData.Position.Bottom);
                            break;
                        case 2:
                            SettingsData.setDockPosition(SettingsData.Position.Left);
                            break;
                        case 3:
                            SettingsData.setDockPosition(SettingsData.Position.Right);
                            break;
                        }
                    }
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "apps"
                title: I18n.tr("Behavior")
                settingKey: "dockBehavior"

                SettingsToggleRow {
                    settingKey: "dockIsolateDisplays"
                    tags: ["dock", "isolate", "monitor", "multi-monitor"]
                    text: I18n.tr("Isolate Displays")
                    description: I18n.tr("Only show windows from the current monitor on each dock")
                    checked: SettingsData.dockIsolateDisplays
                    onToggled: checked => SettingsData.set("dockIsolateDisplays", checked)
                }

                SettingsToggleRow {
                    settingKey: "dockGroupByApp"
                    tags: ["dock", "group", "windows", "app"]
                    text: I18n.tr("Group by App")
                    description: I18n.tr("Group multiple windows of the same app together with a window count indicator")
                    checked: SettingsData.dockGroupByApp
                    onToggled: checked => SettingsData.set("dockGroupByApp", checked)
                }

                SettingsToggleRow {
                    settingKey: "dockRestoreSpecialWorkspaceOnClick"
                    tags: ["dock", "hyprland", "special", "workspace", "scratchpad", "restore", "toggle"]
                    text: I18n.tr("Toggle Scratchpad on Click")
                    description: I18n.tr("Clicking the dock icon of a window on a Hyprland special workspace (scratchpad) shows it, and clicking again hides it")
                    checked: SettingsData.dockRestoreSpecialWorkspaceOnClick
                    visible: CompositorService.isHyprland
                    onToggled: checked => SettingsData.set("dockRestoreSpecialWorkspaceOnClick", checked)
                }

                SettingsToggleRow {
                    settingKey: "dockScratchpadBadge"
                    tags: ["dock", "hyprland", "special", "workspace", "scratchpad", "badge", "indicator"]
                    text: I18n.tr("Scratchpad Badge")
                    description: I18n.tr("Mark dock icons for windows on a Hyprland special workspace (scratchpad) with a small corner badge")
                    checked: SettingsData.dockScratchpadBadge
                    visible: CompositorService.isHyprland
                    onToggled: checked => SettingsData.set("dockScratchpadBadge", checked)
                }

                SettingsChoiceRow {
                    settingKey: "dockIndicatorStyle"
                    tags: ["dock", "indicator", "style", "circle", "line"]
                    text: I18n.tr("Indicator Style")
                    model: [I18n.tr("Circle", "dock indicator style option"), I18n.tr("Line", "dock indicator style option")]
                    currentIndex: SettingsData.dockIndicatorStyle === "circle" ? 0 : 1
                    onSelectionChanged: (index, selected) => {
                        if (selected) {
                            SettingsData.set("dockIndicatorStyle", index === 0 ? "circle" : "line");
                        }
                    }
                }

                SettingsSliderRow {
                    settingKey: "dockMaxVisibleApps"
                    tags: ["dock", "overflow", "max", "apps", "limit"]
                    text: I18n.tr("Max Pinned Apps")
                    description: I18n.tr("0 means unlimited")
                    minimum: 0
                    maximum: 30
                    value: SettingsData.dockMaxVisibleApps
                    defaultValue: 0
                    unit: ""
                    onSliderValueChanged: newValue => SettingsData.set("dockMaxVisibleApps", newValue)
                }

                SettingsSliderRow {
                    settingKey: "dockMaxVisibleRunningApps"
                    tags: ["dock", "overflow", "max", "running", "apps", "limit"]
                    text: I18n.tr("Max Running Apps")
                    description: I18n.tr("0 means unlimited")
                    minimum: 0
                    maximum: 30
                    value: SettingsData.dockMaxVisibleRunningApps
                    defaultValue: 0
                    unit: ""
                    onSliderValueChanged: newValue => SettingsData.set("dockMaxVisibleRunningApps", newValue)
                }

                SettingsToggleRow {
                    settingKey: "dockShowOverflowBadge"
                    tags: ["dock", "overflow", "badge", "count", "indicator"]
                    text: I18n.tr("Overflow Badge")
                    description: I18n.tr("Show how many apps are hidden when a limit is active")
                    checked: SettingsData.dockShowOverflowBadge
                    onToggled: checked => SettingsData.set("dockShowOverflowBadge", checked)
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "apps"
                title: I18n.tr("Launcher Button")
                settingKey: "dockLauncher"

                SettingsToggleRow {
                    settingKey: "dockLauncherEnabled"
                    tags: ["dock", "launcher", "button", "apps"]
                    text: I18n.tr("Show Launcher Button")
                    checked: SettingsData.dockLauncherEnabled
                    onToggled: checked => SettingsData.set("dockLauncherEnabled", checked)
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingL
                    visible: SettingsData.dockLauncherEnabled

                    Column {
                        width: parent.width
                        spacing: Theme.spacingM

                        Item {
                            width: parent.width
                            height: logoModeGroup.implicitHeight
                            clip: true

                            SettingsChoiceRow {
                                id: logoModeGroup
                                text: I18n.tr("Icon")
                                model: {
                                    const modes = [I18n.tr("Apps Icon"), I18n.tr("OS Logo"), I18n.tr("VGS Logo")];
                                    if (CompositorService.isNiri) {
                                        modes.push("niri");
                                    } else if (CompositorService.isHyprland) {
                                        modes.push("Hyprland");
                                    } else if (CompositorService.isMango) {
                                        modes.push("mango");
                                    } else if (CompositorService.isSway) {
                                        modes.push("Sway");
                                    } else if (CompositorService.isScroll) {
                                        modes.push("Scroll");
                                    } else if (CompositorService.isMiracle) {
                                        modes.push("Miracle");
                                    } else {
                                        modes.push(I18n.tr("Compositor"));
                                    }
                                    modes.push(I18n.tr("Custom"));
                                    return modes;
                                }
                                currentIndex: {
                                    if (SettingsData.dockLauncherLogoMode === "apps")
                                        return 0;
                                    if (SettingsData.dockLauncherLogoMode === "os")
                                        return 1;
                                    if (SettingsData.dockLauncherLogoMode === "vgs")
                                        return 2;
                                    if (SettingsData.dockLauncherLogoMode === "compositor")
                                        return 3;
                                    if (SettingsData.dockLauncherLogoMode === "custom")
                                        return 4;
                                    return 0;
                                }
                                onSelectionChanged: (index, selected) => {
                                    if (!selected)
                                        return;
                                    switch (index) {
                                    case 0:
                                        SettingsData.set("dockLauncherLogoMode", "apps");
                                        break;
                                    case 1:
                                        SettingsData.set("dockLauncherLogoMode", "os");
                                        break;
                                    case 2:
                                        SettingsData.set("dockLauncherLogoMode", "vgs");
                                        break;
                                    case 3:
                                        SettingsData.set("dockLauncherLogoMode", "compositor");
                                        break;
                                    case 4:
                                        SettingsData.set("dockLauncherLogoMode", "custom");
                                        break;
                                    }
                                }
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        visible: SettingsData.dockLauncherLogoMode === "custom"
                        spacing: Theme.spacingM

                        StyledRect {
                            width: parent.width - selectButton.width - Theme.spacingM
                            height: 36
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.surfaceContainer, 0.9)
                            border.color: Theme.outlineStrong
                            border.width: 1

                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingM
                                anchors.verticalCenter: parent.verticalCenter
                                text: SettingsData.dockLauncherLogoCustomPath || I18n.tr("Select an image file...")
                                font.pixelSize: Theme.fontSizeMedium
                                color: SettingsData.dockLauncherLogoCustomPath ? Theme.surfaceText : Theme.outlineButton
                                width: parent.width - Theme.spacingM * 2
                                elide: Text.ElideMiddle
                            }
                        }

                        VgsActionButton {
                            id: selectButton
                            iconName: "folder_open"
                            width: 36
                            height: 36
                            onClicked: dockLogoFileBrowser.open()
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingL
                        visible: SettingsData.dockLauncherLogoMode !== "apps"

                        Column {
                            width: parent.width
                            spacing: Theme.spacingM

                            Item {
                                width: parent.width
                                height: colorOverrideRow.implicitHeight
                                clip: true

                                Row {
                                    id: colorOverrideRow
                                    width: parent.width
                                    spacing: Theme.spacingM

                                    SettingsChoiceRow {
                                        id: colorModeGroup
                                        width: parent.width - (colorPickerCircle.visible ? colorPickerCircle.width + parent.spacing : 0)
                                        text: I18n.tr("Color Override")
                                        model: [I18n.tr("Default"), I18n.tr("Primary"), I18n.tr("Surface"), I18n.tr("Custom")]
                                        currentIndex: {
                                            const override = SettingsData.dockLauncherLogoColorOverride;
                                            if (override === "")
                                                return 0;
                                            if (override === "primary")
                                                return 1;
                                            if (override === "surface")
                                                return 2;
                                            return 3;
                                        }
                                        onSelectionChanged: (index, selected) => {
                                            if (!selected)
                                                return;
                                            switch (index) {
                                            case 0:
                                                SettingsData.set("dockLauncherLogoColorOverride", "");
                                                break;
                                            case 1:
                                                SettingsData.set("dockLauncherLogoColorOverride", "primary");
                                                break;
                                            case 2:
                                                SettingsData.set("dockLauncherLogoColorOverride", "surface");
                                                break;
                                            case 3:
                                                const currentOverride = SettingsData.dockLauncherLogoColorOverride;
                                                const isPreset = currentOverride === "" || currentOverride === "primary" || currentOverride === "surface";
                                                if (isPreset) {
                                                    SettingsData.set("dockLauncherLogoColorOverride", "#ffffff");
                                                }
                                                break;
                                            }
                                        }
                                    }

                                    Rectangle {
                                        id: colorPickerCircle
                                        visible: {
                                            const override = SettingsData.dockLauncherLogoColorOverride;
                                            return override !== "" && override !== "primary" && override !== "surface";
                                        }
                                        width: 36
                                        height: 36
                                        radius: Theme.controlRadius
                                        color: {
                                            const override = SettingsData.dockLauncherLogoColorOverride;
                                            if (override !== "" && override !== "primary" && override !== "surface")
                                                return override;
                                            return "#ffffff";
                                        }
                                        border.color: Theme.outline
                                        border.width: 1
                                        anchors.verticalCenter: parent.verticalCenter

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (!PopoutService.colorPickerModal)
                                                    return;
                                                PopoutService.colorPickerModal.selectedColor = SettingsData.dockLauncherLogoColorOverride;
                                                PopoutService.colorPickerModal.pickerTitle = I18n.tr("Choose Dock Launcher Logo Color");
                                                PopoutService.colorPickerModal.onColorSelectedCallback = function (selectedColor) {
                                                    SettingsData.set("dockLauncherLogoColorOverride", selectedColor);
                                                };
                                                PopoutService.colorPickerModal.show();
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        SettingsSliderRow {
                            settingKey: "dockLauncherLogoSizeOffset"
                            tags: ["dock", "launcher", "logo", "size", "offset", "scale"]
                            text: I18n.tr("Size Offset")
                            minimum: -12
                            maximum: 12
                            value: SettingsData.dockLauncherLogoSizeOffset
                            defaultValue: 0
                            onSliderValueChanged: newValue => SettingsData.set("dockLauncherLogoSizeOffset", newValue)
                        }

                        Column {
                            width: parent.width
                            spacing: Theme.spacingM
                            visible: {
                                const override = SettingsData.dockLauncherLogoColorOverride;
                                return override !== "" && override !== "primary" && override !== "surface";
                            }

                            SettingsSliderRow {
                                settingKey: "dockLauncherLogoBrightness"
                                tags: ["dock", "launcher", "logo", "brightness", "color"]
                                text: I18n.tr("Brightness")
                                minimum: 0
                                maximum: 100
                                value: Math.round(SettingsData.dockLauncherLogoBrightness * 100)
                                unit: "%"
                                defaultValue: 50
                                onSliderValueChanged: newValue => SettingsData.set("dockLauncherLogoBrightness", newValue / 100)
                            }

                            SettingsSliderRow {
                                settingKey: "dockLauncherLogoContrast"
                                tags: ["dock", "launcher", "logo", "contrast", "color"]
                                text: I18n.tr("Contrast")
                                minimum: 0
                                maximum: 200
                                value: Math.round(SettingsData.dockLauncherLogoContrast * 100)
                                unit: "%"
                                defaultValue: 100
                                onSliderValueChanged: newValue => SettingsData.set("dockLauncherLogoContrast", newValue / 100)
                            }
                        }
                    }
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "delete"
                title: I18n.tr("Trash")
                settingKey: "dockTrash"

                SettingsToggleRow {
                    settingKey: "dockShowTrash"
                    tags: ["dock", "trash", "bin", "recycle"]
                    text: I18n.tr("Show Trash in Dock")
                    description: I18n.tr("Place a trash bin at the end of the dock")
                    checked: SettingsData.dockShowTrash
                    onToggled: checked => SettingsData.set("dockShowTrash", checked)
                }

                SettingsDropdownRow {
                    id: trashFmDropdown
                    settingKey: "dockTrashFileManager"
                    tags: ["dock", "trash", "file", "manager", "nautilus", "thunar", "dolphin", "custom"]
                    text: I18n.tr("Open Trash With")
                    description: I18n.tr("File manager used to open the trash; pick \"custom\" to enter your own command")
                    visible: SettingsData.dockShowTrash
                    currentValue: SettingsData.dockTrashFileManager
                    options: TrashService.availableFileManagers || []
                    onValueChanged: value => SettingsData.set("dockTrashFileManager", value)
                }

                FocusScope {
                    width: parent.width
                    height: visible ? trashCustomCommandColumn.implicitHeight : 0
                    visible: SettingsData.dockShowTrash && SettingsData.dockTrashFileManager === "custom"

                    Column {
                        id: trashCustomCommandColumn
                        width: parent.width
                        spacing: Theme.spacingXS

                        StyledText {
                            text: I18n.tr("Custom Command")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        VgsTextField {
                            id: trashCustomCommandField
                            width: parent.width
                            placeholderText: "pcmanfm trash:///"
                            backgroundColor: Theme.surfaceContainerHighest
                            normalBorderColor: Theme.borderColor
                            focusedBorderColor: Theme.primary
                            text: SettingsData.dockTrashCustomCommand

                            onTextEdited: SettingsData.set("dockTrashCustomCommand", text.trim())
                        }
                    }
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "photo_size_select_large"
                title: I18n.tr("Sizing")
                settingKey: "dockSizing"

                SettingsSliderRow {
                    settingKey: "dockIconSize"
                    tags: ["dock", "icon", "size", "scale"]
                    text: I18n.tr("Icon Size")
                    value: SettingsData.dockIconSize
                    minimum: 24
                    maximum: 96
                    unit: "px"
                    defaultValue: 48
                    onSliderValueChanged: newValue => SettingsData.set("dockIconSize", newValue)
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "space_bar"
                title: I18n.tr("Spacing")
                settingKey: "dockSpacing"
                collapsible: true
                expanded: false

                SettingsSliderRow {
                    text: I18n.tr("Padding")
                    value: SettingsData.dockSpacing
                    minimum: 0
                    maximum: 32
                    unit: "px"
                    defaultValue: 8
                    onSliderValueChanged: newValue => SettingsData.set("dockSpacing", newValue)
                }

                SettingsSliderRow {
                    text: I18n.tr("Exclusive Zone Offset")
                    value: SettingsData.dockBottomGap
                    minimum: -100
                    maximum: 100
                    unit: "px"
                    defaultValue: 0
                    onSliderValueChanged: newValue => SettingsData.set("dockBottomGap", newValue)
                }

                SettingsSliderRow {
                    text: I18n.tr("Margin")
                    value: SettingsData.dockMargin
                    minimum: 0
                    maximum: 100
                    unit: "px"
                    defaultValue: 0
                    onSliderValueChanged: newValue => SettingsData.set("dockMargin", newValue)
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "opacity"
                title: I18n.tr("Opacity")
                settingKey: "dockTransparency"

                SettingsSliderRow {
                    text: I18n.tr("Dock Opacity")
                    value: Math.round(SettingsData.dockTransparency * 100)
                    minimum: 0
                    maximum: 100
                    unit: "%"
                    defaultValue: 85
                    onSliderValueChanged: newValue => SettingsData.set("dockTransparency", newValue / 100)
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "border_style"
                title: I18n.tr("Border")
                settingKey: "dockBorder"
                collapsible: true
                expanded: false

                SettingsToggleRow {
                    text: I18n.tr("Border")
                    description: I18n.tr("Add a border around the dock")
                    checked: SettingsData.dockBorderEnabled
                    onToggled: checked => SettingsData.set("dockBorderEnabled", checked)
                }

                SettingsChoiceRow {
                    text: I18n.tr("Border Color")
                    description: I18n.tr("Accent color used for the dock border")
                    visible: SettingsData.dockBorderEnabled
                    model: [I18n.tr("Surface", "color option"), I18n.tr("Secondary", "color option"), I18n.tr("Primary", "color option")]
                    currentIndex: {
                        switch (SettingsData.dockBorderColor) {
                        case "surfaceText":
                            return 0;
                        case "secondary":
                            return 1;
                        case "primary":
                            return 2;
                        default:
                            return 0;
                        }
                    }
                    onSelectionChanged: (index, selected) => {
                        if (!selected)
                            return;
                        switch (index) {
                        case 0:
                            SettingsData.set("dockBorderColor", "surfaceText");
                            break;
                        case 1:
                            SettingsData.set("dockBorderColor", "secondary");
                            break;
                        case 2:
                            SettingsData.set("dockBorderColor", "primary");
                            break;
                        }
                    }
                }

                SettingsSliderRow {
                    text: I18n.tr("Border Opacity")
                    visible: SettingsData.dockBorderEnabled
                    value: SettingsData.dockBorderOpacity * 100
                    minimum: 0
                    maximum: 100
                    unit: "%"
                    defaultValue: 100
                    onSliderValueChanged: newValue => SettingsData.set("dockBorderOpacity", newValue / 100)
                }

                SettingsSliderRow {
                    text: I18n.tr("Border Thickness")
                    visible: SettingsData.dockBorderEnabled
                    value: SettingsData.dockBorderThickness
                    minimum: 1
                    maximum: 10
                    unit: "px"
                    defaultValue: 1
                    onSliderValueChanged: newValue => SettingsData.set("dockBorderThickness", newValue)
                }
            }
        }
    }
}
