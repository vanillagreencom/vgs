import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// An on and off switch with an optional text after it. The template holds
// `checked` and toggles it on a click, Space or Enter, and moves `position`
// under a drag; the knob follows `visualPosition`, so it drags and mirrors,
// and slides on `motion.duration.fast` when not dragged. The knob colour
// follows the track it sits on.
// Its tokens are `Theme.toggle`, since `switch` is a JavaScript keyword.
T.Switch {
    id: root

    // The content's left padding already holds the indicator and the gap.
    implicitWidth: text !== "" ? implicitContentWidth : implicitIndicatorWidth
    implicitHeight: Math.max(implicitIndicatorHeight, implicitContentHeight)
    spacing: Theme.toggle.gap
    hoverEnabled: true
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text

    indicator: Rectangle {
        implicitWidth: Theme.toggle.width
        implicitHeight: Theme.toggle.height
        y: (root.height - height) / 2
        radius: Theme.toggle.radius
        color: root.checked ? Theme.toggle.on : Theme.toggle.off
        Behavior on color { ColorAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }

        Rectangle {
            readonly property int inset: Theme.toggle.inset
            width: parent.height - 2 * inset
            height: width
            y: inset
            x: inset + root.visualPosition * (parent.width - width - 2 * inset)
            radius: Theme.toggle.radius
            color: root.checked ? Theme.toggle.knobOn : Theme.toggle.knobOff
            Behavior on x { enabled: !root.down; NumberAnimation { duration: Theme.motion.duration.fast; easing.type: Theme.motion.easing.standard } }
        }

        FocusRing { target: root }
    }

    contentItem: Label {
        role: "body"
        text: root.text
        leftPadding: root.indicator.width + root.spacing
        verticalAlignment: Text.AlignVCenter
    }
}
