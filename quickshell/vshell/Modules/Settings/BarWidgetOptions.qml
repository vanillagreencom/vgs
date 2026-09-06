pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root

    required property var widgetData
    property string pluginId: ""
    property string pluginSettingsPath: ""

    signal settingChanged(string settingName, var value)

    readonly property string widgetId: widgetData?.id || ""
    readonly property bool usesPluginSettings: pluginSettingsPath.length > 0
    implicitHeight: usesPluginSettings
        ? (pluginSettingsLoader.item?.implicitHeight || 0)
        : coreOptions.implicitHeight
    height: implicitHeight

    function valueFor(name, fallback) {
        return widgetData && widgetData[name] !== undefined ? widgetData[name] : fallback;
    }

    function setControlCenterValue(name, value) {
        settingChanged(name, value);
        if (value)
            return;
        if (name === "showAudioIcon")
            settingChanged("showAudioPercent", false);
        else if (name === "showMicIcon")
            settingChanged("showMicPercent", false);
        else if (name === "showBrightnessIcon")
            settingChanged("showBrightnessPercent", false);
    }

    function controlCenterDefault(name) {
        const defaults = {
            showNetworkIcon: SettingsData.controlCenterShowNetworkIcon,
            showVpnIcon: SettingsData.controlCenterShowVpnIcon,
            showBluetoothIcon: SettingsData.controlCenterShowBluetoothIcon,
            showAudioIcon: SettingsData.controlCenterShowAudioIcon,
            showAudioPercent: SettingsData.controlCenterShowAudioPercent,
            showMicIcon: SettingsData.controlCenterShowMicIcon,
            showMicPercent: SettingsData.controlCenterShowMicPercent,
            showBrightnessIcon: SettingsData.controlCenterShowBrightnessIcon,
            showBrightnessPercent: SettingsData.controlCenterShowBrightnessPercent,
            showBatteryIcon: SettingsData.controlCenterShowBatteryIcon,
            showPrinterIcon: SettingsData.controlCenterShowPrinterIcon,
            showScreenSharingIcon: SettingsData.controlCenterShowScreenSharingIcon,
            showIdleInhibitorIcon: SettingsData.controlCenterShowIdleInhibitorIcon,
            showDoNotDisturbIcon: SettingsData.controlCenterShowDoNotDisturbIcon
        };
        return defaults[name] ?? false;
    }

    readonly property var controlCenterGroups: [
        { id: "network", label: I18n.tr("Network"), settings: [{ name: "showNetworkIcon", label: I18n.tr("Show Network") }] },
        { id: "vpn", label: I18n.tr("VPN"), settings: [{ name: "showVpnIcon", label: I18n.tr("Show VPN") }] },
        { id: "bluetooth", label: I18n.tr("Bluetooth"), settings: [{ name: "showBluetoothIcon", label: I18n.tr("Show Bluetooth") }] },
        { id: "audio", label: I18n.tr("Audio"), settings: [{ name: "showAudioIcon", label: I18n.tr("Show Audio") }, { name: "showAudioPercent", label: I18n.tr("Show Volume") }] },
        { id: "microphone", label: I18n.tr("Microphone"), settings: [{ name: "showMicIcon", label: I18n.tr("Show Microphone") }, { name: "showMicPercent", label: I18n.tr("Show Microphone Volume") }] },
        { id: "brightness", label: I18n.tr("Brightness"), settings: [{ name: "showBrightnessIcon", label: I18n.tr("Show Brightness") }, { name: "showBrightnessPercent", label: I18n.tr("Show Brightness Value") }] },
        { id: "battery", label: I18n.tr("Battery"), settings: [{ name: "showBatteryIcon", label: I18n.tr("Show Battery") }] },
        { id: "printer", label: I18n.tr("Printer"), settings: [{ name: "showPrinterIcon", label: I18n.tr("Show Printer") }] },
        { id: "screenSharing", label: I18n.tr("Screen Sharing"), settings: [{ name: "showScreenSharingIcon", label: I18n.tr("Show Screen Sharing") }] },
        { id: "idleInhibitor", label: I18n.tr("Idle Inhibitor"), settings: [{ name: "showIdleInhibitorIcon", label: I18n.tr("Show Idle Inhibitor") }] },
        { id: "doNotDisturb", label: I18n.tr("Do Not Disturb"), settings: [{ name: "showDoNotDisturbIcon", label: I18n.tr("Show Do Not Disturb") }] }
    ]

    function orderedControlCenterGroups() {
        const order = valueFor("controlCenterGroupOrder", controlCenterGroups.map(group => group.id));
        const byId = {};
        controlCenterGroups.forEach(group => byId[group.id] = group);
        const result = [];
        order.forEach(id => {
            if (byId[id]) {
                result.push(byId[id]);
                delete byId[id];
            }
        });
        controlCenterGroups.forEach(group => {
            if (byId[group.id])
                result.push(group);
        });
        return result;
    }

    function moveControlCenterGroup(index, delta) {
        const groups = orderedControlCenterGroups();
        const target = index + delta;
        if (target < 0 || target >= groups.length)
            return;
        const moved = groups.splice(index, 1)[0];
        groups.splice(target, 0, moved);
        settingChanged("controlCenterGroupOrder", groups.map(group => group.id));
    }

    Loader {
        id: pluginSettingsLoader
        width: parent.width
        active: root.usesPluginSettings
        asynchronous: false
        source: active ? (root.pluginSettingsPath.startsWith("file://") ? root.pluginSettingsPath : "file://" + root.pluginSettingsPath) : ""

        onLoaded: {
            if (item && "pluginService" in item)
                item.pluginService = PluginService;
            if (item && "popoutService" in item)
                item.popoutService = PopoutService;
        }
    }

    Column {
        id: coreOptions
        width: parent.width
        spacing: Theme.spacingS
        visible: !root.usesPluginSettings

        OptionToggle {
            visible: ["cpuUsage", "memUsage", "diskUsage", "cpuTemp", "gpuTemp"].includes(root.widgetId)
            text: I18n.tr("Force minimum width")
            description: I18n.tr("Keep monitor values from changing the surrounding bar layout")
            checked: root.valueFor("minimumWidth", true)
            onChanged: value => root.settingChanged("minimumWidth", value)
        }

        OptionToggle {
            visible: root.widgetId === "memUsage"
            text: I18n.tr("Show Swap")
            checked: root.valueFor("showSwap", false)
            onChanged: value => root.settingChanged("showSwap", value)
        }

        OptionToggle {
            visible: root.widgetId === "memUsage"
            text: I18n.tr("Show in GB")
            checked: root.valueFor("showInGb", false)
            onChanged: value => root.settingChanged("showInGb", value)
        }

        VgsDropdown {
            width: parent.width
            visible: root.widgetId === "gpuTemp"
            text: I18n.tr("GPU")
            description: I18n.tr("Device used by the temperature widget")
            options: (DgopService.availableGpus || []).map(gpu => gpu.displayName || gpu.pciId || gpu.driver || I18n.tr("GPU"))
            currentValue: {
                const index = root.valueFor("selectedGpuIndex", 0);
                return options[index] || options[0] || "";
            }
            onValueChanged: value => {
                const index = options.indexOf(value);
                if (index >= 0)
                    root.settingChanged("selectedGpuIndex", index);
            }
        }

        VgsDropdown {
            width: parent.width
            visible: root.widgetId === "diskUsage"
            text: I18n.tr("Mount")
            description: I18n.tr("Filesystem shown by the disk widget")
            options: (DgopService.diskMounts && DgopService.diskMounts.length > 0)
                ? DgopService.diskMounts.map(mount => mount.mount)
                : ["/"]
            currentValue: root.valueFor("mountPath", "/")
            onValueChanged: value => root.settingChanged("mountPath", value)
        }

        VgsDropdown {
            width: parent.width
            visible: root.widgetId === "diskUsage"
            text: I18n.tr("Display")
            options: [I18n.tr("Percentage"), I18n.tr("Total"), I18n.tr("Remaining"), I18n.tr("Remaining / Total")]
            currentValue: options[root.valueFor("diskUsageMode", 0)] || options[0]
            onValueChanged: value => root.settingChanged("diskUsageMode", Math.max(0, options.indexOf(value)))
        }

        OptionToggle {
            visible: ["clock", "focusedWindow", "runningApps", "keyboard_layout_name"].includes(root.widgetId)
            text: I18n.tr("Compact Mode")
            checked: {
                if (root.widgetId === "clock")
                    return root.valueFor("clockCompactMode", SettingsData.clockCompactMode);
                if (root.widgetId === "focusedWindow")
                    return root.valueFor("focusedWindowCompactMode", SettingsData.focusedWindowCompactMode);
                if (root.widgetId === "runningApps")
                    return root.valueFor("runningAppsCompactMode", SettingsData.runningAppsCompactMode);
                return root.valueFor("keyboardLayoutNameCompactMode", SettingsData.keyboardLayoutNameCompactMode);
            }
            onChanged: value => {
                const names = {
                    clock: "clockCompactMode",
                    focusedWindow: "focusedWindowCompactMode",
                    runningApps: "runningAppsCompactMode",
                    keyboard_layout_name: "keyboardLayoutNameCompactMode"
                };
                root.settingChanged(names[root.widgetId], value);
            }
        }

        VgsDropdown {
            width: parent.width
            visible: root.widgetId === "focusedWindow" || root.widgetId === "music"
            text: I18n.tr("Size")
            options: [I18n.tr("Small"), I18n.tr("Medium"), I18n.tr("Large"), I18n.tr("Largest")]
            currentValue: {
                const value = root.widgetId === "music"
                    ? root.valueFor("mediaSize", SettingsData.mediaSize)
                    : root.valueFor("focusedWindowSize", SettingsData.focusedWindowSize);
                return options[value] || options[1];
            }
            onValueChanged: value => root.settingChanged(root.widgetId === "music" ? "mediaSize" : "focusedWindowSize", Math.max(0, options.indexOf(value)))
        }

        OptionToggle {
            visible: root.widgetId === "keyboard_layout_name"
            text: I18n.tr("Show Icon")
            checked: root.valueFor("keyboardLayoutNameShowIcon", SettingsData.keyboardLayoutNameShowIcon)
            onChanged: value => root.settingChanged("keyboardLayoutNameShowIcon", value)
        }

        OptionToggle {
            visible: root.widgetId === "runningApps"
            text: I18n.tr("Group by App")
            checked: root.valueFor("runningAppsGroupByApp", SettingsData.runningAppsGroupByApp)
            onChanged: value => root.settingChanged("runningAppsGroupByApp", value)
        }

        OptionToggle {
            visible: root.widgetId === "runningApps"
            text: I18n.tr("Current Workspace")
            checked: root.valueFor("runningAppsCurrentWorkspace", SettingsData.runningAppsCurrentWorkspace)
            onChanged: value => root.settingChanged("runningAppsCurrentWorkspace", value)
        }

        OptionToggle {
            visible: root.widgetId === "runningApps"
            text: I18n.tr("Current Monitor")
            checked: root.valueFor("runningAppsCurrentMonitor", SettingsData.runningAppsCurrentMonitor)
            onChanged: value => root.settingChanged("runningAppsCurrentMonitor", value)
        }

        OptionToggle {
            visible: root.widgetId === "battery"
            text: I18n.tr("Show Percentage")
            checked: root.valueFor("showBatteryPercent", SettingsData.showBatteryPercent)
            onChanged: value => root.settingChanged("showBatteryPercent", value)
        }

        OptionToggle {
            visible: root.widgetId === "battery"
            text: I18n.tr("Percentage Only on Battery")
            checked: root.valueFor("showBatteryPercentOnlyOnBattery", SettingsData.showBatteryPercentOnlyOnBattery)
            onChanged: value => root.settingChanged("showBatteryPercentOnlyOnBattery", value)
        }

        OptionToggle {
            visible: root.widgetId === "battery"
            text: I18n.tr("Show Remaining Time")
            checked: root.valueFor("showBatteryTime", SettingsData.showBatteryTime)
            onChanged: value => root.settingChanged("showBatteryTime", value)
        }

        OptionToggle {
            visible: root.widgetId === "battery"
            text: I18n.tr("Time Only on Battery")
            checked: root.valueFor("showBatteryTimeOnlyOnBattery", SettingsData.showBatteryTimeOnlyOnBattery)
            onChanged: value => root.settingChanged("showBatteryTimeOnlyOnBattery", value)
        }

        OptionToggle {
            visible: root.widgetId === "systemTray"
            text: I18n.tr("Inline Expansion")
            checked: root.valueFor("trayUseInlineExpansion", false)
            onChanged: value => root.settingChanged("trayUseInlineExpansion", value)
        }

        OptionToggle {
            visible: root.widgetId === "systemTray"
            enabled: !root.valueFor("trayUseInlineExpansion", false)
            text: I18n.tr("Single-Line Popup")
            checked: root.valueFor("trayPopupSingleLine", SettingsData.trayPopupSingleLine)
            onChanged: value => root.settingChanged("trayPopupSingleLine", value)
        }

        OptionToggle {
            visible: root.widgetId === "systemTray"
            text: I18n.tr("Auto Overflow")
            checked: root.valueFor("trayAutoOverflow", SettingsData.trayAutoOverflow)
            onChanged: value => root.settingChanged("trayAutoOverflow", value)
        }

        NumberStepper {
            visible: root.widgetId === "systemTray"
            text: I18n.tr("Max Visible Items")
            value: root.valueFor("trayMaxVisibleItems", SettingsData.trayMaxVisibleItems)
            minimum: 0
            maximum: 20
            zeroLabel: I18n.tr("All")
            onChanged: value => root.settingChanged("trayMaxVisibleItems", value)
        }

        NumberStepper {
            visible: root.widgetId === "spacer"
            text: I18n.tr("Spacer Size")
            value: root.valueFor("size", 20)
            minimum: 5
            maximum: 5000
            step: 5
            onChanged: value => root.settingChanged("size", value)
        }

        Column {
            width: parent.width
            spacing: Theme.spacingS
            visible: root.widgetId === "controlCenterButton"

            StyledText {
                width: parent.width
                text: I18n.tr("Control Center Groups")
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            Repeater {
                model: root.orderedControlCenterGroups()

                delegate: Column {
                    required property var modelData
                    required property int index
                    width: parent.width
                    spacing: Theme.spacingXS

                    Row {
                        width: parent.width

                        StyledText {
                            width: parent.width - groupOrderButtons.width
                            text: modelData.label
                            font.pixelSize: Theme.settingsFontSize
                            font.weight: Font.Medium
                            color: Theme.surfaceVariantText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Row {
                            id: groupOrderButtons
                            spacing: Theme.spacingXS

                            VgsActionButton {
                                buttonSize: 28
                                iconName: "arrow_upward"
                                iconSize: 16
                                enabled: index > 0
                                onClicked: root.moveControlCenterGroup(index, -1)
                            }
                            VgsActionButton {
                                buttonSize: 28
                                iconName: "arrow_downward"
                                iconSize: 16
                                enabled: index < root.orderedControlCenterGroups().length - 1
                                onClicked: root.moveControlCenterGroup(index, 1)
                            }
                        }
                    }

                    Repeater {
                        model: modelData.settings

                        VgsToggle {
                            required property var modelData
                            width: parent.width
                            horizontalPadding: 0
                            rowHoverHighlight: false
                            text: modelData.label
                            checked: root.valueFor(modelData.name, root.controlCenterDefault(modelData.name))
                            onToggled: value => root.setControlCenterValue(modelData.name, value)
                        }
                    }
                }
            }
        }

        PrivacyWidgetOptions {
            options: root
        }

        PrinterWidgetOptions {
            options: root
        }

        Column {
            width: parent.width
            spacing: Theme.spacingS
            visible: root.widgetId === "appsDock"

            StyledText {
                text: I18n.tr("Overflow")
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }
            NumberStepper {
                text: I18n.tr("Max Pinned Apps")
                value: root.valueFor("barMaxVisibleApps", SettingsData.barMaxVisibleApps)
                minimum: 0
                maximum: 100
                zeroLabel: I18n.tr("All")
                onChanged: value => root.settingChanged("barMaxVisibleApps", value)
            }
            NumberStepper {
                text: I18n.tr("Max Running Apps")
                value: root.valueFor("barMaxVisibleRunningApps", SettingsData.barMaxVisibleRunningApps)
                minimum: 0
                maximum: 100
                zeroLabel: I18n.tr("All")
                onChanged: value => root.settingChanged("barMaxVisibleRunningApps", value)
            }
            OptionToggle {
                text: I18n.tr("Show Overflow Badge")
                checked: root.valueFor("barShowOverflowBadge", SettingsData.barShowOverflowBadge)
                onChanged: value => root.settingChanged("barShowOverflowBadge", value)
            }

            StyledText {
                text: I18n.tr("Visual Effects")
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }
            OptionToggle {
                text: I18n.tr("Hide Indicators")
                checked: SettingsData.appsDockHideIndicators
                onChanged: value => SettingsData.set("appsDockHideIndicators", value)
            }
            OptionToggle {
                text: I18n.tr("Colorize Active")
                checked: SettingsData.appsDockColorizeActive
                onChanged: value => SettingsData.set("appsDockColorizeActive", value)
            }
            VgsDropdown {
                width: parent.width
                visible: SettingsData.appsDockColorizeActive
                text: I18n.tr("Active Color")
                options: [I18n.tr("Primary"), I18n.tr("Secondary"), I18n.tr("Primary Container"), I18n.tr("Error"), I18n.tr("Success")]
                currentValue: {
                    const keys = ["primary", "secondary", "primaryContainer", "error", "success"];
                    const index = keys.indexOf(SettingsData.appsDockActiveColorMode);
                    return options[index >= 0 ? index : 0];
                }
                onValueChanged: value => {
                    const keys = ["primary", "secondary", "primaryContainer", "error", "success"];
                    SettingsData.set("appsDockActiveColorMode", keys[Math.max(0, options.indexOf(value))]);
                }
            }
            OptionToggle {
                text: I18n.tr("Enlarge on Hover")
                checked: SettingsData.appsDockEnlargeOnHover
                onChanged: value => SettingsData.set("appsDockEnlargeOnHover", value)
            }
            NumberStepper {
                visible: SettingsData.appsDockEnlargeOnHover
                text: I18n.tr("Enlargement %")
                value: SettingsData.appsDockEnlargePercentage
                minimum: 100
                maximum: 150
                step: 5
                suffix: "%"
                onChanged: value => SettingsData.set("appsDockEnlargePercentage", value)
            }
            NumberStepper {
                text: I18n.tr("Icon Size %")
                value: SettingsData.appsDockIconSizePercentage
                minimum: 50
                maximum: 200
                step: 5
                suffix: "%"
                onChanged: value => SettingsData.set("appsDockIconSizePercentage", value)
            }
        }
    }

    component OptionToggle: VgsToggle {
        id: optionToggle
        signal changed(bool value)
        width: parent?.width || 0
        horizontalPadding: 0
        rowHoverHighlight: false
        onToggled: value => changed(value)
    }

    component NumberStepper: Item {
        id: stepper
        property string text: ""
        property int value: 0
        property int minimum: 0
        property int maximum: 100
        property int step: 1
        property string zeroLabel: ""
        property string suffix: ""
        signal changed(int value)

        width: parent?.width || 0
        height: 40

        StyledText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: stepper.text
            font.pixelSize: Theme.fontSizeMedium
            color: Theme.surfaceText
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            VgsActionButton {
                buttonSize: 28
                iconName: "remove"
                iconSize: 16
                enabled: stepper.value > stepper.minimum
                onClicked: stepper.changed(Math.max(stepper.minimum, stepper.value - stepper.step))
            }
            StyledText {
                width: 52
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignHCenter
                text: stepper.value === 0 && stepper.zeroLabel ? stepper.zeroLabel : stepper.value + stepper.suffix
                font.pixelSize: Theme.settingsFontSize
                color: Theme.surfaceText
            }
            VgsActionButton {
                buttonSize: 28
                iconName: "add"
                iconSize: 16
                enabled: stepper.value < stepper.maximum
                onClicked: stepper.changed(Math.min(stepper.maximum, stepper.value + stepper.step))
            }
        }
    }
}
