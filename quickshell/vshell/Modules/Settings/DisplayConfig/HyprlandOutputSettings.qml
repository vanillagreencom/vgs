import QtQuick
import QtQuick.Dialogs
import qs.Common
import qs.Widgets
import qs.Modules.Settings.Widgets

Column {
    id: root
    property string outputName: ""
    property var outputData: null
    property bool expanded: true
    readonly property int depth: setting("bitdepth", 8)
    readonly property string cm: setting("colorManagement", "auto")
    readonly property string icc: setting("icc", "")
    readonly property bool hdr: ["hdr", "hdredid"].includes(cm)
    readonly property bool disabled: setting("disabled", false)
    readonly property bool studio: outputData?.model === "StudioDisplay"
    readonly property bool apple: studio || outputData?.model === "ProDisplayXDR"
    readonly property var colorValues: ["auto", "srgb", "dp3", "dcip3", "adobe", "wide", "edid"]
    readonly property var colorLabels: [I18n.tr("Automatic"), "sRGB", "Display P3", "DCI-P3", "Adobe RGB", "BT.2020", I18n.tr("Display native (EDID)")]
    width: parent.width
    spacing: Theme.spacingM

    function setting(key, fallback) {
        DisplayConfigState.pendingHyprlandChanges;
        return DisplayConfigState.getHyprlandSetting(outputData, outputName, key, fallback);
    }
    function set(key, value) {
        DisplayConfigState.setHyprlandSetting(outputData, outputName, key, value);
    }

    StyledText {
        text: I18n.tr("Colour and dynamic range")
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceText
    }
    VgsDropdown {
        width: parent.width
        text: I18n.tr("Colour depth")
        description: I18n.tr("10-bit reduces colour banding.")
        options: [I18n.tr("8-bit"), I18n.tr("10-bit")]
        currentValue: root.depth === 10 ? options[1] : options[0]
        enabled: !root.disabled
        onValueChanged: value => {
            const depth = value === options[1] ? 10 : 8;
            root.set("bitdepth", depth);
            if (depth === 8 && root.hdr)
                root.set("colorManagement", "srgb");
        }
    }
    VgsDropdown {
        width: parent.width
        text: I18n.tr("Colour mode")
        enabled: !root.disabled && !root.hdr && root.icc === ""
        options: root.colorLabels
        currentValue: root.hdr ? I18n.tr("HDR (PQ)") : root.icc ? I18n.tr("ICC profile") : root.colorLabels[root.colorValues.indexOf(root.cm)] || root.cm
        onValueChanged: value => {
            const index = root.colorLabels.indexOf(value);
            if (index >= 0)
                root.set("colorManagement", root.colorValues[index]);
        }
    }
    Column {
        width: parent.width
        spacing: Theme.spacingS
        StyledText {
            text: I18n.tr("Colour profile")
            font.pixelSize: Theme.fontSizeMedium
            color: Theme.surfaceText
        }
        StyledText {
            width: parent.width
            wrapMode: Text.WrapAnywhere
            text: root.icc || I18n.tr("Uses your compositor profile.")
            font.pixelSize: Theme.settingsFontSize
            color: Theme.surfaceVariantText
        }
        Row {
            spacing: Theme.spacingM
            VgsButton {
                text: I18n.tr("Choose profile…")
                variant: "secondary"
                enabled: !root.disabled && !root.hdr
                onClicked: profileDialog.open()
            }
            VgsButton {
                text: I18n.tr("Remove profile")
                variant: "secondary"
                visible: root.icc !== ""
                onClicked: root.set("icc", "")
            }
        }
    }
    FileDialog {
        id: profileDialog
        title: I18n.tr("Choose a display ICC profile")
        nameFilters: [I18n.tr("ICC profiles (*.icc *.icm)")]
        onAccepted: root.set("icc", decodeURIComponent(String(selectedFile).replace(/^file:\/\//, "")))
    }
    VgsToggle {
        width: parent.width
        text: I18n.tr("High Dynamic Range (HDR)")
        checked: root.hdr
        enabled: !root.disabled && !root.studio && root.icc === ""
        description: root.studio ? I18n.tr("Studio Display supports SDR only.") : root.icc ? I18n.tr("Remove the colour profile to enable HDR.") : I18n.tr("Requires an HDR display and GPU.")
        onToggled: checked => {
            if (checked)
                root.set("bitdepth", 10);
            root.set("colorManagement", checked ? "hdr" : "srgb");
        }
    }
    Column {
        width: parent.width
        spacing: Theme.spacingS
        visible: root.hdr
        StyledText {
            text: I18n.tr("SDR content brightness")
            font.pixelSize: Theme.settingsFontSize
            color: Theme.surfaceText
        }
        VgsSlider {
            width: parent.width
            minimum: 10
            maximum: 500
            value: Math.round(root.setting("sdrBrightness", 1) * 100)
            wheelEnabled: false
            onSliderValueChanged: value => root.set("sdrBrightness", value / 100)
        }
        StyledText {
            text: I18n.tr("SDR content saturation")
            font.pixelSize: Theme.settingsFontSize
            color: Theme.surfaceText
        }
        VgsSlider {
            width: parent.width
            minimum: 0
            maximum: 300
            value: Math.round(root.setting("sdrSaturation", 1) * 100)
            wheelEnabled: false
            onSliderValueChanged: value => root.set("sdrSaturation", value / 100)
        }
    }
    StyledText {
        width: parent.width
        visible: root.apple
        wrapMode: Text.WordWrap
        text: I18n.tr("VGS does not support Apple presets, True Tone, auto brightness or calibration.")
        font.pixelSize: Theme.settingsFontSize
        color: Theme.surfaceVariantText
    }
    SettingsDivider {}
    VgsDropdown {
        width: parent.width
        text: I18n.tr("Mirror display")
        enabled: !root.disabled
        options: [I18n.tr("None")].concat(Object.keys(DisplayConfigState.outputs).filter(name => name !== root.outputName))
        currentValue: DisplayConfigState.getEffectiveValue(root.outputName, "mirror", root.outputData?.mirror || "") || I18n.tr("None")
        onValueChanged: value => DisplayConfigState.setPendingChange(root.outputName, "mirror", value === I18n.tr("None") ? "" : value)
    }
    VgsToggle {
        width: parent.width
        text: I18n.tr("Use this display")
        checked: !root.disabled
        enabled: !checked || DisplayConfigState.canDisableOutput()
        description: enabled ? "" : I18n.tr("At least one display must remain enabled.")
        onToggled: checked => root.set("disabled", !checked)
    }
}
