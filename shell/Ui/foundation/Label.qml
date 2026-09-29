import QtQuick
import qs.Commons

// Text in one typography role of the theme: `role` names a group of
// `Theme.text`, and the family, size, weight, letter spacing, line height,
// case and colour follow it. A role the theme lacks is logged and drawn as
// body. Both `font.weight` and `font.variableAxes` carry the weight, since
// a variable font moves on the axis alone and a static family on the
// weight alone. Letter spacing is stated in em and set in pixels here.
// `lineBox` is the role's font-size multiple, floored at the font's own
// line box rounded up to a whole pixel. `halfLeading` is the extra line space above and below each
// fixed line. `capCentre` is the first line's capital centre from the
// label top. `opticalWidth` removes the tracking Qt adds after the last
// glyph. `topForCapCenter()` gives the top that puts the capital centre on
// a box centre with a whole-pixel baseline.
Text {
    id: root

    property string role: "body"
    readonly property var typography: typographyOf(role)
    readonly property real fontHeight: metrics.height
    readonly property real lineBox: Math.max(Math.round(typography.size * typography.lineHeight), Math.ceil(fontHeight))
    readonly property real halfLeading: Math.max(0, (lineBox - fontHeight) / 2)
    readonly property real capCentre: metrics.ascent - metrics.capitalHeight / 2
    readonly property real opticalWidth: Math.max(0, implicitWidth - (text === "" ? 0 : font.letterSpacing))

    function typographyOf(name) {
        const found = Theme.text[name];
        if (found !== undefined) return found;
        console.error("Label: no text role named " + JSON.stringify(name));
        return Theme.text.body;
    }

    color: typography.color
    font.family: typography.family
    font.pixelSize: typography.size
    font.weight: typography.weight
    font.variableAxes: ({ wght: typography.weight })
    font.letterSpacing: typography.letterSpacing * typography.size
    font.capitalization: typography.uppercase ? Font.AllUppercase : Font.MixedCase
    lineHeight: lineBox > fontHeight ? lineBox : 1
    lineHeightMode: lineBox > fontHeight ? Text.FixedHeight : Text.ProportionalHeight

    function topForCapCenter(boxHeight) {
        return Math.round(boxHeight / 2 + metrics.capitalHeight / 2) - metrics.ascent;
    }

    FontMetrics {
        id: metrics
        font: root.font
    }
}
