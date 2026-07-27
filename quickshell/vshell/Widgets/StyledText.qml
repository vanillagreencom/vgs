import QtQuick
import qs.Common

Text {
    property bool isMonospace: false
    // Keep VGS lean: do not vendor large font assets here.
    // VGS vendors its UI font; Fira Code is a system font.
    FontLoader {
        id: interFont
        source: Qt.resolvedUrl("../assets/fonts/inter/InterVariable.ttf")
    }

    FontLoader {
        id: firaCodeFont
        source: "file:///usr/share/fonts/TTF/FiraCode-Regular.ttf"
    }

    readonly property string resolvedFontFamily: {
        const requestedFont = isMonospace ? Theme.monoFontFamily : Theme.fontFamily;
        const defaultFont = isMonospace ? Theme.defaultMonoFontFamily : Theme.defaultFontFamily;

        if (requestedFont === defaultFont) {
            return isMonospace ? firaCodeFont.name : interFont.name;
        }
        return requestedFont;
    }

    readonly property int resolvedRenderType: {
        switch (SettingsData.textRenderType) {
        case SettingsData.TextRenderType.Qt:
            return Text.QtRendering;
        case SettingsData.TextRenderType.Curve:
            return Text.CurveRendering;
        default:
            return Text.NativeRendering;
        }
    }

    readonly property int resolvedRenderQuality: {
        switch (SettingsData.textRenderQuality) {
        case SettingsData.TextRenderQuality.Low:
            return Text.LowRenderTypeQuality;
        case SettingsData.TextRenderQuality.Normal:
            return Text.NormalRenderTypeQuality;
        case SettingsData.TextRenderQuality.High:
            return Text.HighRenderTypeQuality;
        case SettingsData.TextRenderQuality.VeryHigh:
            return Text.VeryHighRenderTypeQuality;
        default:
            return Text.DefaultRenderTypeQuality;
        }
    }

    readonly property int resolvedHintingPreference: SettingsData.textHintingPreference
    readonly property int resolvedLineHeightMode: SettingsData.textLineHeightMode === "fixed" ? Text.FixedHeight : Text.ProportionalHeight
    readonly property var resolvedVariableAxes: {
        const axes = {};
        if (SettingsData.textUseVariableWeight)
            axes["wght"] = SettingsData.textVariableWeight;
        if (SettingsData.textUseOpticalSize)
            axes["opsz"] = SettingsData.textOpticalSize;
        return axes;
    }
    readonly property var resolvedFontFeatures: {
        const features = {};
        features["kern"] = SettingsData.textKerning ? 1 : 0;
        features["liga"] = SettingsData.textFeatureLigatures ? 1 : 0;
        features["clig"] = SettingsData.textFeatureLigatures ? 1 : 0;
        features["tnum"] = SettingsData.textFeatureTabularNumbers ? 1 : 0;
        const stylisticSet = Math.max(0, Math.min(20, SettingsData.textFeatureStylisticSet || 0));
        if (stylisticSet > 0)
            features["ss" + (stylisticSet < 10 ? "0" : "") + stylisticSet] = 1;
        return features;
    }

    readonly property var standardAnimation: {
        "duration": Appearance.anim.durations.normal,
        "easing.type": Easing.BezierSpline,
        "easing.bezierCurve": Appearance.anim.curves.standard
    }

    color: Theme.surfaceText
    font.pixelSize: Appearance.fontSize.normal
    font.family: resolvedFontFamily
    font.weight: Theme.fontWeight
    font.hintingPreference: resolvedHintingPreference
    font.letterSpacing: SettingsData.textLetterSpacing
    font.wordSpacing: SettingsData.textWordSpacing
    font.kerning: SettingsData.textKerning
    font.variableAxes: resolvedVariableAxes
    font.features: resolvedFontFeatures
    lineHeight: SettingsData.textLineHeight
    lineHeightMode: resolvedLineHeightMode
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    elide: Text.ElideRight
    verticalAlignment: Text.AlignVCenter
    antialiasing: SettingsData.textAntialiasing
    renderType: resolvedRenderType
    renderTypeQuality: resolvedRenderQuality

    Behavior on opacity {
        NumberAnimation {
            duration: standardAnimation.duration
            easing.type: standardAnimation["easing.type"]
            easing.bezierCurve: standardAnimation["easing.bezierCurve"]
        }
    }
}
