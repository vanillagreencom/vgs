import QtQuick
import qs.Commons
import qs.Ui

// The label of a checkbox, a radio or a switch, internal to the module:
// the control's text in `item`, its line box on a whole pixel centred in
// the control, after the indicator and the control's spacing.
// `indicatorY(height)` is where an indicator that tall centres on the
// label's capital centre on a whole pixel, or on the control without text.
Label {
    id: label

    required property Item control
    readonly property real lineTop: Math.round((control.height - lineBox) / 2)

    function indicatorY(height) {
        return control.text !== "" ? Math.round(lineTop + capCentre - height / 2) : Math.round((control.height - height) / 2);
    }

    role: "item"
    text: control.text
    leftPadding: control.indicator.width + control.spacing
    topPadding: lineTop
    verticalAlignment: Text.AlignTop
}
