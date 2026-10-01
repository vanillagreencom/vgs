import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui
import "../foundation/KeyNavLogic.js" as KeyNavLogic

// A checkbox with an optional text after it. The template holds `checked`
// and toggles it on a click, Space or Enter; the box fills with the
// checked colour and draws the check icon on it. Hover strengthens the
// outline, or the checked fill, and a press fills the box. The text draws
// in `item`; the box centres on its capital centre on a whole pixel, and
// the control is never shorter than `size.control.sm`, so a click just
// beside the box still reaches it.
T.CheckBox {
    id: root

    property bool focusPreview: false

    // The content's left padding already holds the indicator and the gap.
    implicitWidth: text !== "" ? implicitContentWidth : implicitIndicatorWidth
    implicitHeight: Math.max(Theme.size.control.sm, implicitIndicatorHeight, implicitContentHeight)
    spacing: Theme.checkbox.gap
    hoverEnabled: true
    PointerCursor {}
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text
    Keys.onReturnPressed: KeyNavLogic.activate(root)
    Keys.onEnterPressed: KeyNavLogic.activate(root)

    indicator: Rectangle {
        implicitWidth: Theme.checkbox.size
        implicitHeight: Theme.checkbox.size
        y: root.contentItem.indicatorY(height)
        radius: Theme.checkbox.radius
        color: root.checked ? (root.down ? Theme.checkbox.checkedPressed : root.hovered ? Theme.checkbox.checkedHover : Theme.checkbox.checked) : root.down ? Theme.checkbox.pressed : Theme.checkbox.background
        border.width: Theme.checkbox.border
        border.color: root.checked ? color : root.hovered || root.down ? Theme.checkbox.hoverBorder : Theme.checkbox.borderColor
        Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }

        Icon {
            anchors.centerIn: parent
            name: "check"
            size: Theme.icon.size.xs
            color: Theme.checkbox.mark
            visible: root.checked
        }

        FocusRing { target: root }
    }

    contentItem: IndicatorLabel { control: root }
}
