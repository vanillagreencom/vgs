import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// A checkbox with an optional text after it. The template holds `checked`
// and toggles it on a click, Space or Enter; the box fills with the
// checked colour and draws the check icon on it.
T.CheckBox {
    id: root

    // The content's left padding already holds the indicator and the gap.
    implicitWidth: text !== "" ? implicitContentWidth : implicitIndicatorWidth
    implicitHeight: Math.max(implicitIndicatorHeight, implicitContentHeight)
    spacing: Theme.checkbox.gap
    hoverEnabled: true
    PointerCursor {}
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text

    indicator: Rectangle {
        implicitWidth: Theme.checkbox.size
        implicitHeight: Theme.checkbox.size
        y: (root.height - height) / 2
        radius: Theme.checkbox.radius
        color: root.checked ? Theme.checkbox.checked : Theme.checkbox.background
        border.width: Theme.checkbox.border
        border.color: root.checked ? Theme.checkbox.checked : Theme.checkbox.borderColor
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

    contentItem: Label {
        role: "body"
        text: root.text
        leftPadding: root.indicator.width + root.spacing
        verticalAlignment: Text.AlignVCenter
    }
}
