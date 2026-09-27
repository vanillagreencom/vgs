import QtQuick
import qs.Commons

// Text in one typography role of the theme: `role` names a group of
// `Theme.text`, and the family, size, weight, letter spacing, line height,
// case and colour follow it. A role the theme lacks is logged and drawn as
// body. Both `font.weight` and `font.variableAxes` carry the weight, since
// a variable font moves on the axis alone and a static family on the
// weight alone. Letter spacing is stated in em and set in pixels here.
Text {
    id: root

    property string role: "body"
    readonly property var typography: typographyOf(role)

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
    lineHeight: typography.lineHeight
    lineHeightMode: Text.ProportionalHeight
}
