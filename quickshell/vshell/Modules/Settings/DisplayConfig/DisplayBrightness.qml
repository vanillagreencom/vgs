import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "DisplaySettingsLogic.js" as DisplaySettingsLogic

Column {
    id: root
    required property string outputName
    required property var outputData
    readonly property var devices: (DisplayService.devices || []).filter(device => DisplayService.isDisplayBrightnessClass(device.class))
    readonly property string pinKey: {
        const screen = Quickshell.screens.find(screen => screen.name === outputName);
        return screen ? SettingsData.getScreenDisplayName(screen) : outputName;
    }
    readonly property string deviceName: DisplaySettingsLogic.brightnessDeviceName(outputName, outputData, devices, (SettingsData.brightnessDevicePins || {})[pinKey])
    readonly property var device: devices.find(device => device.name === deviceName) || null
    readonly property string colorMode: outputData?.hyprlandSettings?.colorManagement || ""
    readonly property bool xdrHdr: outputData?.model === "ProDisplayXDR" && ["hdr", "hdredid"].includes(colorMode)
    property bool chooseDevice: false
    spacing: Theme.spacingS

    Item {
        width: parent.width
        height: Math.max(brightnessLabel.implicitHeight, brightness.height) + Theme.spacingS * 2
        Column {
            id: brightnessLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - brightness.width - Theme.spacingL
            spacing: Theme.spacingXS
            StyledText {
                text: I18n.tr("Brightness")
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
            }
            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.xdrHdr ? I18n.tr("In HDR, use SDR brightness below.") : root.device ? I18n.tr("Adjusts this display immediately.") : I18n.tr("Select a brightness device for this display.")
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.settingsFontSize
            }
        }
        VgsSlider {
            id: brightness
            width: Math.min(300, parent.width * 0.48)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            enabled: root.device !== null && !root.xdrHdr
            minimum: 1
            maximum: root.device ? (SessionData.getBrightnessExponential(root.device.id) ? 100 : root.device.displayMax || 100) : 100
            unit: root.device?.class === "ddc" && !SessionData.getBrightnessExponential(root.device.id) ? "" : "%"
            leftIcon: "brightness_6"
            rightIcon: "light_mode"
            wheelEnabled: false
            onSliderValueChanged: value => {
                if (root.device)
                    DisplayService.setBrightness(value, root.deviceName, true);
            }
            Binding on value {
                when: !brightness.isDragging
                value: {
                    DisplayService.brightnessVersion;
                    return root.device ? DisplayService.getDeviceBrightness(root.deviceName) : 0;
                }
            }
        }
    }
    VgsButton {
        text: root.chooseDevice ? I18n.tr("Hide brightness device") : I18n.tr("Change brightness device…")
        variant: "secondary"
        visible: root.device !== null
        onClicked: root.chooseDevice = !root.chooseDevice
    }
    VgsDropdown {
        width: parent.width
        text: I18n.tr("Brightness device")
        visible: !root.device || root.chooseDevice
        options: [I18n.tr("Automatic")].concat(root.devices.map(device => (device.label || device.name) + " · " + device.name))
        currentValue: {
            const pinned = (SettingsData.brightnessDevicePins || {})[root.pinKey];
            const found = root.devices.find(device => device.name === pinned);
            return found ? (found.label || found.name) + " · " + found.name : I18n.tr("Automatic");
        }
        onValueChanged: value => {
            const pins = Object.assign({}, SettingsData.brightnessDevicePins || {});
            const index = options.indexOf(value) - 1;
            if (index < 0)
                delete pins[root.pinKey];
            else
                pins[root.pinKey] = root.devices[index].name;
            SettingsData.brightnessDevicePins = pins;
            SettingsData.saveSettings();
        }
    }
}
