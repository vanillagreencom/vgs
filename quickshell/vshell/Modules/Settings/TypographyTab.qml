import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root

    property var cachedFontFamilies: []
    property var cachedMonoFamilies: []
    property bool fontsEnumerated: false
    readonly property string sessionType: (Quickshell.env("XDG_SESSION_TYPE") || "").toLowerCase()
    readonly property bool subpixelAvailable: sessionType === "x11" || sessionType === "xorg"

    function setAppFont(key, value) {
        SettingsData.set("systemFontsManaged", true);
        SettingsData.set(key, value === "Default" ? "" : value);
    }

    function rendererIndex() {
        switch (SettingsData.textRenderType) {
        case SettingsData.TextRenderType.Qt:
            return 1;
        case SettingsData.TextRenderType.Curve:
            return 2;
        default:
            return 0;
        }
    }

    function setRenderer(index) {
        switch (index) {
        case 1:
            SettingsData.set("textRenderType", SettingsData.TextRenderType.Qt);
            break;
        case 2:
            SettingsData.set("textRenderType", SettingsData.TextRenderType.Curve);
            break;
        default:
            SettingsData.set("textRenderType", SettingsData.TextRenderType.Native);
            break;
        }
    }

    function hintingIndex() {
        switch (SettingsData.textHintingPreference) {
        case Font.PreferNoHinting:
            return 1;
        case Font.PreferVerticalHinting:
            return 2;
        case Font.PreferFullHinting:
            return 3;
        default:
            return 0;
        }
    }

    function setHinting(index) {
        const values = [Font.PreferDefaultHinting, Font.PreferNoHinting, Font.PreferVerticalHinting, Font.PreferFullHinting];
        SettingsData.set("textHintingPreference", values[Math.max(0, Math.min(values.length - 1, index))]);
    }

    function fontWeightLabel(weight) {
        switch (weight) {
        case Font.Thin:
            return I18n.tr("Thin", "font weight");
        case Font.ExtraLight:
            return I18n.tr("Extra Light", "font weight");
        case Font.Light:
            return I18n.tr("Light", "font weight");
        case Font.Medium:
            return I18n.tr("Medium", "font weight");
        case Font.DemiBold:
            return I18n.tr("Demi Bold", "font weight");
        case Font.Bold:
            return I18n.tr("Bold", "font weight");
        case Font.ExtraBold:
            return I18n.tr("Extra Bold", "font weight");
        case Font.Black:
            return I18n.tr("Black", "font weight");
        default:
            return I18n.tr("Regular", "font weight");
        }
    }

    function weightFromLabel(value) {
        if (value === I18n.tr("Thin", "font weight"))
            return Font.Thin;
        if (value === I18n.tr("Extra Light", "font weight"))
            return Font.ExtraLight;
        if (value === I18n.tr("Light", "font weight"))
            return Font.Light;
        if (value === I18n.tr("Medium", "font weight"))
            return Font.Medium;
        if (value === I18n.tr("Demi Bold", "font weight"))
            return Font.DemiBold;
        if (value === I18n.tr("Bold", "font weight"))
            return Font.Bold;
        if (value === I18n.tr("Extra Bold", "font weight"))
            return Font.ExtraBold;
        if (value === I18n.tr("Black", "font weight"))
            return Font.Black;
        return Font.Normal;
    }

    function enumerateFonts() {
        var fonts = [];
        var availableFonts = Qt.fontFamilies();

        for (var i = 0; i < availableFonts.length; i++) {
            var fontName = availableFonts[i];
            if (fontName.startsWith("."))
                continue;
            fonts.push(fontName);
        }
        fonts.sort();
        fonts.unshift("Default");
        cachedFontFamilies = fonts;
        cachedMonoFamilies = fonts;
    }

    Timer {
        id: fontEnumerationTimer
        interval: 50
        running: false
        onTriggered: {
            if (fontsEnumerated)
                return;
            enumerateFonts();
            fontsEnumerated = true;
        }
    }

    Component.onCompleted: {
        fontEnumerationTimer.start();
    }

    VgsFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn
            topPadding: Theme.spacingXS
            width: Math.min(680, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            SettingsCard {
                tab: "typography"
                title: I18n.tr("System fonts")
                settingKey: "systemFonts"
                iconName: "desktop_windows"
                SettingsDropdownRow {
                    tab: "typography"
                    settingKey: "systemFontInterfaceFamily"
                    text: I18n.tr("App interface")
                    description: I18n.tr("Apps that use system fonts.")
                    options: root.cachedFontFamilies
                    currentValue: SettingsData.systemFontInterfaceFamily || "Default"
                    enableFuzzySearch: true
                    onValueChanged: value => root.setAppFont("systemFontInterfaceFamily", value)
                }

                SettingsDropdownRow {
                    tab: "typography"
                    settingKey: "systemFontMonoFamily"
                    text: I18n.tr("Monospace")
                    description: I18n.tr("Some terminals use their own font.")
                    options: root.cachedFontFamilies
                    currentValue: SettingsData.systemFontMonoFamily || "Default"
                    enableFuzzySearch: true
                    onValueChanged: value => root.setAppFont("systemFontMonoFamily", value)
                }

                SettingsSliderRow {
                    tab: "typography"
                    settingKey: "systemFontSize"
                    text: I18n.tr("App text size")
                    enabled: SettingsData.systemFontsManaged
                    description: I18n.tr("Reopen apps to see changes.")
                    minimum: 6
                    maximum: 32
                    unit: " pt"
                    value: SettingsData.systemFontSize
                    onSliderValueChanged: value => SettingsData.set("systemFontSize", value)
                }
                SettingsDropdownRow {
                    tab: "typography"
                    settingKey: "hyprlandFontFamily"
                    visible: CompositorService.isHyprland
                    text: I18n.tr("Hyprland text")
                    description: I18n.tr("Group titles and messages. Default follows the app font.")
                    options: root.cachedFontFamilies
                    currentValue: SettingsData.hyprlandFontFamily || "Default"
                    enableFuzzySearch: true
                    onValueChanged: value => SettingsData.set("hyprlandFontFamily", value === "Default" ? "" : value)
                }

                StyledText {
                    width: parent.width
                    text: I18n.tr("The quick brown fox jumps over the lazy dog.")
                    font.family: SettingsData.systemFontInterfaceFamily || "sans-serif"
                    font.pixelSize: Theme.fontSizeLarge
                    wrapMode: Text.WordWrap
                    topPadding: Theme.spacingM
                    bottomPadding: Theme.spacingM
                    color: Theme.surfaceText
                }
                SettingsCard {
                    id: appAdvanced
                    title: I18n.tr("Advanced app rendering")
                    collapsible: true
                    expanded: false
                    SettingsToggleRow {
                        tab: "typography"
                        tags: ["font", "system", "managed", "reset"]
                        settingKey: "systemFontsManaged"
                        text: I18n.tr("Manage System Rendering")
                        description: I18n.tr("Turn off to remove VGS font overrides.")
                        checked: SettingsData.systemFontsManaged
                        onToggled: checked => SettingsData.set("systemFontsManaged", checked)
                    }

                    Row {
                        width: parent.width
                        height: Math.max(resetText.implicitHeight, resetButton.height)
                        spacing: Theme.spacingM

                        StyledText {
                            id: resetText
                            width: parent.width - resetButton.width - parent.spacing
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.subpixelAvailable ? I18n.tr("X11 can use subpixel antialiasing when the monitor subpixel order is known.") : I18n.tr("Wayland sessions default to grayscale because physical subpixel order is not reliable across outputs.")
                            font.pixelSize: Theme.settingsFontSize
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }

                        VgsButton {
                            id: resetButton
                            anchors.verticalCenter: parent.verticalCenter
                            variant: "secondary"
                            text: I18n.tr("Reset")
                            iconName: "restart_alt"
                            buttonHeight: 36
                            onClicked: {
                                SettingsData.set("systemFontsManaged", false);
                            }
                        }
                    }

                    SettingsDivider {}

                    SystemFontRenderingSection {
                        title: I18n.tr("Interface / App Fonts")
                        settingPrefix: "systemFontInterface"
                        baseTags: ["interface"]
                        controlsEnabled: SettingsData.systemFontsManaged
                        subpixelAvailable: root.subpixelAvailable
                        antialiasDescription: I18n.tr("Smooth proportional UI text in GTK, Qt, browsers, and fontconfig-aware apps")
                        hintingDescription: I18n.tr("Slight preserves spacing on HiDPI; full is mainly for low-DPI displays")
                        subpixelDescriptionAvailable: I18n.tr("LCD subpixel order for X11 displays")
                    }

                    SettingsDivider {}

                    SystemFontRenderingSection {
                        title: I18n.tr("Monospace / Terminal Fonts")
                        note: I18n.tr("This fontconfig override is scoped to monospace text. GPU terminals with their own font renderers still need their app-specific font settings.")
                        settingPrefix: "systemFontMono"
                        baseTags: ["monospace", "terminal"]
                        controlsEnabled: SettingsData.systemFontsManaged
                        subpixelAvailable: root.subpixelAvailable
                        antialiasDescription: I18n.tr("Smooth monospace text in fontconfig-aware apps and terminals")
                        hintingDescription: I18n.tr("Slight is the portable default; full can make code spacing uneven")
                        subpixelDescriptionAvailable: I18n.tr("LCD subpixel order for X11 monospace text")
                    }
                }
            }

            SettingsCard {
                tab: "typography"
                tags: ["font", "family", "text", "typography", "quickshell", "shell"]
                title: I18n.tr("Shell appearance")
                settingKey: "typography"
                iconName: "text_fields"

                SettingsDropdownRow {
                    tab: "typography"
                    tags: ["font", "family", "normal", "text"]
                    settingKey: "fontFamily"
                    text: I18n.tr("Shell font")
                    description: I18n.tr("Bars, menus and VGS settings.")
                    options: root.fontsEnumerated ? root.cachedFontFamilies : ["Default"]
                    currentValue: SettingsData.fontFamily === Theme.defaultFontFamily ? "Default" : (SettingsData.fontFamily || "Default")
                    enableFuzzySearch: true
                    popupWidthOffset: 100
                    maxPopupHeight: 400
                    onValueChanged: value => {
                        if (value === "Default")
                            SettingsData.set("fontFamily", Theme.defaultFontFamily);
                        else
                            SettingsData.set("fontFamily", value);
                    }
                }

                SettingsDropdownRow {
                    tab: "typography"
                    tags: ["font", "monospace", "code", "terminal"]
                    settingKey: "monoFontFamily"
                    text: I18n.tr("Shell monospace")
                    description: I18n.tr("Code and fixed-width text.")
                    options: root.fontsEnumerated ? root.cachedMonoFamilies : ["Default"]
                    currentValue: SettingsData.monoFontFamily === Theme.defaultMonoFontFamily ? "Default" : (SettingsData.monoFontFamily || "Default")
                    enableFuzzySearch: true
                    popupWidthOffset: 100
                    maxPopupHeight: 400
                    onValueChanged: value => {
                        if (value === "Default")
                            SettingsData.set("monoFontFamily", Theme.defaultMonoFontFamily);
                        else
                            SettingsData.set("monoFontFamily", value);
                    }
                }

                SettingsDivider {}

                SettingsDropdownRow {
                    tab: "typography"
                    tags: ["font", "weight", "bold", "light"]
                    settingKey: "fontWeight"
                    text: I18n.tr("Font Weight")
                    description: I18n.tr("Shell text weight.")
                    options: [I18n.tr("Thin", "font weight"), I18n.tr("Extra Light", "font weight"), I18n.tr("Light", "font weight"), I18n.tr("Regular", "font weight"), I18n.tr("Medium", "font weight"), I18n.tr("Demi Bold", "font weight"), I18n.tr("Bold", "font weight"), I18n.tr("Extra Bold", "font weight"), I18n.tr("Black", "font weight")]
                    currentValue: root.fontWeightLabel(SettingsData.fontWeight)
                    onValueChanged: value => SettingsData.set("fontWeight", root.weightFromLabel(value))
                }

                SettingsSliderRow {
                    tab: "typography"
                    tags: ["font", "scale", "size", "zoom"]
                    settingKey: "fontScale"
                    text: I18n.tr("Font Scale")
                    description: I18n.tr("Resize all shell text.")
                    minimum: 75
                    maximum: 150
                    value: Math.round(SettingsData.fontScale * 100)
                    unit: "%"
                    defaultValue: 100
                    onSliderValueChanged: newValue => SettingsData.set("fontScale", newValue / 100)
                }

                SettingsCard {
                    id: shellAdvanced
                    title: I18n.tr("Advanced shell typography")
                    collapsible: true
                    expanded: false
                    SettingsDivider {}

                    SettingsToggleRow {
                        tab: "typography"
                        tags: ["font", "variable", "weight", "axis", "inter"]
                        settingKey: "textUseVariableWeight"
                        text: I18n.tr("Variable Weight Axis")
                        description: I18n.tr("Adjust weight continuously on variable fonts.")
                        checked: SettingsData.textUseVariableWeight
                        onToggled: checked => SettingsData.set("textUseVariableWeight", checked)
                    }

                    SettingsSliderRow {
                        tab: "typography"
                        tags: ["font", "variable", "weight", "axis", "wght"]
                        settingKey: "textVariableWeight"
                        text: I18n.tr("Weight Axis")
                        description: I18n.tr("Requires a variable font.")
                        minimum: 100
                        maximum: 900
                        step: 10
                        value: SettingsData.textVariableWeight
                        unit: ""
                        defaultValue: 400
                        enabled: SettingsData.textUseVariableWeight
                        opacity: enabled ? 1 : 0.45
                        onSliderValueChanged: newValue => SettingsData.set("textVariableWeight", newValue)
                    }

                    SettingsToggleRow {
                        tab: "typography"
                        tags: ["font", "variable", "optical", "opsz"]
                        settingKey: "textUseOpticalSize"
                        text: I18n.tr("Optical Size Axis")
                        description: I18n.tr("Requires a font with optical sizing.")
                        checked: SettingsData.textUseOpticalSize
                        onToggled: checked => SettingsData.set("textUseOpticalSize", checked)
                    }

                    SettingsSliderRow {
                        tab: "typography"
                        tags: ["font", "variable", "optical", "opsz"]
                        settingKey: "textOpticalSize"
                        text: I18n.tr("Optical Size")
                        minimum: 8
                        maximum: 48
                        value: SettingsData.textOpticalSize
                        unit: ""
                        defaultValue: 14
                        enabled: SettingsData.textUseOpticalSize
                        opacity: enabled ? 1 : 0.45
                        onSliderValueChanged: newValue => SettingsData.set("textOpticalSize", newValue)
                    }

                    SettingsChoiceRow {
                        tab: "typography"
                        tags: ["text", "renderer", "native", "qt", "curve"]
                        settingKey: "textRenderType"
                        text: I18n.tr("Renderer")
                        description: I18n.tr("Native uses system rendering. Qt and Curve use the GPU.")
                        model: [I18n.tr("Native"), I18n.tr("Qt"), I18n.tr("Curve")]
                        currentIndex: root.rendererIndex()
                        onSelectionChanged: (index, selected) => {
                            if (selected)
                                root.setRenderer(index);
                        }
                    }

                    SettingsDivider {}

                    SettingsChoiceRow {
                        tab: "typography"
                        tags: ["text", "render", "quality"]
                        settingKey: "textRenderQuality"
                        text: I18n.tr("Render Quality")
                        description: SettingsData.textRenderType === SettingsData.TextRenderType.Native ? I18n.tr("Native rendering ignores this setting") : I18n.tr("Higher quality uses more GPU memory.")
                        model: [I18n.tr("Default"), I18n.tr("Low"), I18n.tr("Normal"), I18n.tr("High"), I18n.tr("Very High")]
                        currentIndex: SettingsData.textRenderQuality
                        enabled: SettingsData.textRenderType !== SettingsData.TextRenderType.Native
                        opacity: enabled ? 1 : 0.45
                        onSelectionChanged: (index, selected) => {
                            if (selected)
                                SettingsData.set("textRenderQuality", index);
                        }
                    }

                    SettingsChoiceRow {
                        tab: "typography"
                        tags: ["text", "hinting", "native", "freetype"]
                        settingKey: "textHintingPreference"
                        text: I18n.tr("Hinting")
                        description: SettingsData.textRenderType === SettingsData.TextRenderType.Native ? I18n.tr("Full hinting can change letter spacing.") : I18n.tr("Hinting only applies to Native rendering")
                        model: [I18n.tr("Default"), I18n.tr("None"), I18n.tr("Vertical"), I18n.tr("Full")]
                        currentIndex: root.hintingIndex()
                        enabled: SettingsData.textRenderType === SettingsData.TextRenderType.Native
                        opacity: enabled ? 1 : 0.45
                        onSelectionChanged: (index, selected) => {
                            if (selected)
                                root.setHinting(index);
                        }
                    }

                    SettingsToggleRow {
                        tab: "typography"
                        tags: ["text", "antialiasing", "native"]
                        settingKey: "textAntialiasing"
                        text: I18n.tr("Shell Antialiasing")
                        description: SettingsData.textRenderType === SettingsData.TextRenderType.Native ? I18n.tr("Qt and Curve always smooth text.") : I18n.tr("Only Native rendering can disable antialiasing")
                        checked: SettingsData.textAntialiasing
                        enabled: SettingsData.textRenderType === SettingsData.TextRenderType.Native
                        opacity: enabled ? 1 : 0.45
                        onToggled: checked => SettingsData.set("textAntialiasing", checked)
                    }

                    SettingsDivider {}

                    SettingsSliderRow {
                        tab: "typography"
                        tags: ["text", "tracking", "letter", "spacing"]
                        settingKey: "textLetterSpacing"
                        text: I18n.tr("Letter Spacing")
                        minimum: -10
                        maximum: 20
                        value: Math.round(SettingsData.textLetterSpacing * 10)
                        unit: " /10 px"
                        defaultValue: 0
                        onSliderValueChanged: newValue => SettingsData.set("textLetterSpacing", newValue / 10)
                    }

                    SettingsSliderRow {
                        tab: "typography"
                        tags: ["text", "word", "spacing"]
                        settingKey: "textWordSpacing"
                        text: I18n.tr("Word Spacing")
                        minimum: -10
                        maximum: 40
                        value: Math.round(SettingsData.textWordSpacing * 10)
                        unit: " /10 px"
                        defaultValue: 0
                        onSliderValueChanged: newValue => SettingsData.set("textWordSpacing", newValue / 10)
                    }

                    SettingsSliderRow {
                        tab: "typography"
                        tags: ["text", "line", "height"]
                        settingKey: "textLineHeight"
                        text: I18n.tr("Line Height")
                        minimum: 90
                        maximum: 180
                        value: Math.round(SettingsData.textLineHeight * 100)
                        unit: "%"
                        defaultValue: 100
                        onSliderValueChanged: newValue => SettingsData.set("textLineHeight", newValue / 100)
                    }

                    SettingsChoiceRow {
                        tab: "typography"
                        tags: ["text", "line", "height", "mode"]
                        settingKey: "textLineHeightMode"
                        text: I18n.tr("Line Height Mode")
                        description: I18n.tr("Proportional follows text size. Fixed uses pixels.")
                        model: [I18n.tr("Proportional"), I18n.tr("Fixed")]
                        currentIndex: SettingsData.textLineHeightMode === "fixed" ? 1 : 0
                        onSelectionChanged: (index, selected) => {
                            if (selected)
                                SettingsData.set("textLineHeightMode", index === 1 ? "fixed" : "proportional");
                        }
                    }

                    SettingsDivider {}

                    SettingsToggleRow {
                        tab: "typography"
                        tags: ["text", "kerning", "opentype"]
                        settingKey: "textKerning"
                        text: I18n.tr("Kerning")
                        description: I18n.tr("Use the font's spacing for letter pairs.")
                        checked: SettingsData.textKerning
                        onToggled: checked => SettingsData.set("textKerning", checked)
                    }

                    SettingsToggleRow {
                        tab: "typography"
                        tags: ["text", "ligatures", "opentype", "features"]
                        settingKey: "textFeatureLigatures"
                        text: I18n.tr("Ligatures")
                        description: I18n.tr("Join letter pairs where the font supports it.")
                        checked: SettingsData.textFeatureLigatures
                        onToggled: checked => SettingsData.set("textFeatureLigatures", checked)
                    }

                    SettingsToggleRow {
                        tab: "typography"
                        tags: ["text", "numbers", "tabular", "opentype", "features"]
                        settingKey: "textFeatureTabularNumbers"
                        text: I18n.tr("Tabular Numbers")
                        description: I18n.tr("Align digits in clocks and counters.")
                        checked: SettingsData.textFeatureTabularNumbers
                        onToggled: checked => SettingsData.set("textFeatureTabularNumbers", checked)
                    }

                    SettingsDropdownRow {
                        tab: "typography"
                        tags: ["text", "stylistic", "set", "opentype", "features"]
                        settingKey: "textFeatureStylisticSet"
                        text: I18n.tr("Stylistic Set")
                        description: I18n.tr("Requires a font with alternate styles.")
                        options: [I18n.tr("None"), "ss01", "ss02", "ss03", "ss04", "ss05", "ss06", "ss07", "ss08", "ss09", "ss10", "ss11", "ss12", "ss13", "ss14", "ss15", "ss16", "ss17", "ss18", "ss19", "ss20"]
                        currentValue: SettingsData.textFeatureStylisticSet > 0 ? ("ss" + (SettingsData.textFeatureStylisticSet < 10 ? "0" : "") + SettingsData.textFeatureStylisticSet) : I18n.tr("None")
                        onValueChanged: value => SettingsData.set("textFeatureStylisticSet", value === I18n.tr("None") ? 0 : parseInt(String(value).replace("ss", "")))
                    }

                    Rectangle {
                        width: parent.width
                        height: Theme.spacingXL * 3
                        radius: Theme.cornerRadius
                        color: Theme.elevatedRowColor

                        StyledText {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacingL
                            anchors.rightMargin: Theme.spacingL
                            text: I18n.tr("Aa 12345 1/2 -> fi ffi -- VGS text preview")
                            font.pixelSize: Theme.fontSizeLarge
                            color: Theme.surfaceText
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }
        }
    }
}
