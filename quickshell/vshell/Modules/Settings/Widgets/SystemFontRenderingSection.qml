pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Widgets

Column {
    id: root

    property string title: ""
    property string note: ""
    property string settingPrefix: ""
    property var baseTags: []
    property bool controlsEnabled: true
    property bool subpixelAvailable: false
    property string antialiasDescription: ""
    property string hintingDescription: ""
    property string subpixelDescriptionAvailable: ""
    property string subpixelDescriptionUnavailable: I18n.tr("Disabled on Wayland; VGS applies grayscale")

    readonly property var systemHintingValues: ["none", "slight", "medium", "full"]
    readonly property var systemSubpixelValues: ["none", "rgb", "bgr", "vrgb", "vbgr"]
    readonly property var systemLcdFilterValues: ["default", "light", "legacy", "none"]
    readonly property string antialiasKey: settingPrefix + "Antialias"
    readonly property string hintingKey: settingPrefix + "Hinting"
    readonly property string subpixelKey: settingPrefix + "Subpixel"
    readonly property string lcdFilterKey: settingPrefix + "LcdFilter"
    readonly property string autohintKey: settingPrefix + "Autohint"

    function optionIndex(values, value) {
        const idx = values.indexOf(value);
        return idx >= 0 ? idx : 0;
    }

    function tags(extra) {
        return ["font", "system"].concat(baseTags).concat(extra);
    }

    width: parent?.width ?? 0
    enabled: controlsEnabled
    opacity: enabled ? 1 : 0.45
    spacing: Theme.spacingS

    StyledText {
        width: parent.width
        text: root.title
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: root.note
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
        visible: root.note !== ""
    }

    SettingsToggleRow {
        tab: "typography"
        tags: root.tags(["antialias"])
        settingKey: root.antialiasKey
        text: I18n.tr("Antialiasing")
        description: root.antialiasDescription
        checked: !!SettingsData[root.antialiasKey]
        onToggled: checked => SettingsData.set(root.antialiasKey, checked)
    }

    SettingsButtonGroupRow {
        tab: "typography"
        tags: root.tags(["hinting"])
        settingKey: root.hintingKey
        text: I18n.tr("Hinting")
        description: root.hintingDescription
        model: [I18n.tr("None"), I18n.tr("Slight"), I18n.tr("Medium"), I18n.tr("Full")]
        currentIndex: root.optionIndex(root.systemHintingValues, SettingsData[root.hintingKey])
        onSelectionChanged: (index, selected) => {
            if (selected)
                SettingsData.set(root.hintingKey, root.systemHintingValues[index]);
        }
    }

    SettingsButtonGroupRow {
        tab: "typography"
        tags: root.tags(["subpixel", "rgba"])
        settingKey: root.subpixelKey
        text: I18n.tr("Subpixel")
        description: root.subpixelAvailable ? root.subpixelDescriptionAvailable : root.subpixelDescriptionUnavailable
        model: [I18n.tr("None"), "RGB", "BGR", "VRGB", "VBGR"]
        currentIndex: root.optionIndex(root.systemSubpixelValues, SettingsData[root.subpixelKey])
        enabled: root.subpixelAvailable
        opacity: enabled ? 1 : 0.45
        onSelectionChanged: (index, selected) => {
            if (selected)
                SettingsData.set(root.subpixelKey, root.systemSubpixelValues[index]);
        }
    }

    SettingsButtonGroupRow {
        tab: "typography"
        tags: root.tags(["lcd", "filter"])
        settingKey: root.lcdFilterKey
        text: I18n.tr("LCD Filter")
        description: I18n.tr("Filter used when subpixel antialiasing is active")
        model: [I18n.tr("Default"), I18n.tr("Light"), I18n.tr("Legacy"), I18n.tr("None")]
        currentIndex: root.optionIndex(root.systemLcdFilterValues, SettingsData[root.lcdFilterKey])
        onSelectionChanged: (index, selected) => {
            if (selected)
                SettingsData.set(root.lcdFilterKey, root.systemLcdFilterValues[index]);
        }
    }

    SettingsToggleRow {
        tab: "typography"
        tags: root.tags(["autohint"])
        settingKey: root.autohintKey
        text: I18n.tr("Autohint")
        description: I18n.tr("Use FreeType autohinting instead of the font's native hints")
        checked: !!SettingsData[root.autohintKey]
        onToggled: checked => SettingsData.set(root.autohintKey, checked)
    }
}
