import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// One option of a set. Radios under one parent are exclusive, as the
// template makes them: checking one unchecks its siblings. A click, Space
// or Enter checks the focused one.
T.RadioButton {
    id: root

    // The content's left padding already holds the indicator and the gap.
    implicitWidth: text !== "" ? implicitContentWidth : implicitIndicatorWidth
    implicitHeight: Math.max(Theme.size.control.sm, implicitIndicatorHeight, implicitContentHeight)
    spacing: Theme.radio.gap
    hoverEnabled: true
    PointerCursor {}
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text

    indicator: Rectangle {
        implicitWidth: Theme.radio.size
        implicitHeight: Theme.radio.size
        y: root.contentItem.indicatorY(height)
        radius: Theme.radius.full
        color: root.down ? Theme.radio.pressed : Theme.radio.background
        border.width: Theme.radio.border
        border.color: root.checked ? (root.down ? Theme.radio.checkedPressed : root.hovered ? Theme.radio.checkedHover : Theme.radio.checked) : root.hovered || root.down ? Theme.radio.hoverBorder : Theme.radio.borderColor

        Rectangle {
            anchors.centerIn: parent
            width: Theme.radio.dot
            height: Theme.radio.dot
            radius: Theme.radius.full
            color: Theme.radio.checked
            visible: root.checked
        }

        FocusRing { target: root }
    }

    contentItem: IndicatorLabel { control: root }
}
