import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// An on and off switch with an optional text after it. `size` is `md`, the
// default, or `sm` for inline rows. The template holds `checked` and
// toggles it on a click, Space or Enter, and moves `position` under a drag;
// the knob follows `visualPosition`, so it drags and mirrors, and slides
// on `motion.duration.fast` when not dragged. The knob colour follows the
// track it sits on. Hover lightens the track and a press widens the knob.
// The text draws in `item`; the track centres on its capital centre on a
// whole pixel, and the control is never shorter than `size.control.sm`,
// so a compact track keeps a larger input area.
// Its tokens are `Theme.toggle`, since `switch` is a JavaScript keyword.
T.Switch {
    id: root

    property string size: "md"
    readonly property var sizeTokens: sizeOf(size)

    function sizeOf(name) {
        const found = Theme.toggle.size[name];
        if (found !== undefined) return found;
        console.error("Switch: no size named " + JSON.stringify(name));
        return Theme.toggle.size.md;
    }

    // The content's left padding already holds the indicator and the gap.
    implicitWidth: text !== "" ? implicitContentWidth : implicitIndicatorWidth
    implicitHeight: Math.max(Theme.size.control.sm, implicitIndicatorHeight, implicitContentHeight)
    spacing: Theme.toggle.gap
    hoverEnabled: true
    PointerCursor {}
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text

    indicator: Rectangle {
        implicitWidth: root.sizeTokens.width
        implicitHeight: root.sizeTokens.height
        y: root.contentItem.indicatorY(height)
        radius: Theme.toggle.radius
        color: root.checked ? (root.hovered || root.down ? Theme.toggle.onHover : Theme.toggle.on) : root.hovered || root.down ? Theme.toggle.offHover : Theme.toggle.off
        Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }

        Rectangle {
            readonly property int inset: Theme.toggle.inset
            width: parent.height - 2 * inset + (root.down ? 2 * inset : 0)
            height: parent.height - 2 * inset
            y: inset
            x: inset + root.visualPosition * (parent.width - width - 2 * inset)
            radius: Theme.toggle.radius
            color: root.checked ? Theme.toggle.knobOn : Theme.toggle.knobOff
            Behavior on x { enabled: !root.down; NumberAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
        }

        FocusRing { target: root }
    }

    contentItem: IndicatorLabel { control: root }
}
