import QtQuick
import qs.Common
import qs.Services

TextMetrics {
    property bool isMonospace: false

    readonly property string resolvedFontFamily: {
        const requestedFont = isMonospace ? SettingsData.monoFontFamily : SettingsData.fontFamily;
        const defaultFont = isMonospace ? Theme.defaultMonoFontFamily : Theme.defaultFontFamily;

        if (requestedFont === defaultFont) {
            // Resolve through the bundled faces so metrics measure the exact
            // family StyledText renders, not a system-dependent substitute.
            return isMonospace ? Theme.bundledMonoFontName : Theme.bundledFontName;
        }
        return requestedFont;
    }

    font.pixelSize: Appearance.fontSize.normal
    font.family: resolvedFontFamily
    font.weight: SettingsData.fontWeight
    font.hintingPreference: SettingsData.textHintingPreference
    font.letterSpacing: SettingsData.textLetterSpacing
    font.wordSpacing: SettingsData.textWordSpacing
    font.kerning: SettingsData.textKerning
    font.variableAxes: {
        const axes = {};
        if (SettingsData.textUseVariableWeight)
            axes["wght"] = SettingsData.textVariableWeight;
        if (SettingsData.textUseOpticalSize)
            axes["opsz"] = SettingsData.textOpticalSize;
        return axes;
    }
}
