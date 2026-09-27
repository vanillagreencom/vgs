import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// One option of a set. Radios under one parent are exclusive, as the
// template makes them: checking one unchecks its siblings. A click, Space
// or Enter checks the focused one.
T.RadioButton {
    id: root

    implicitWidth: implicitIndicatorWidth + (text !== "" ? spacing + implicitContentWidth : 0)
    implicitHeight: Math.max(implicitIndicatorHeight, implicitContentHeight)
    spacing: Theme.radio.gap
    hoverEnabled: true
    opacity: enabled ? 1 : Theme.opacity.disabled
    Accessible.name: text

    indicator: Rectangle {
        implicitWidth: Theme.radio.size
        implicitHeight: Theme.radio.size
        y: (root.height - height) / 2
        radius: Theme.radius.full
        color: Theme.radio.background
        border.width: Theme.radio.border
        border.color: root.checked ? Theme.radio.checked : Theme.radio.borderColor

        Rectangle {
            anchors.centerIn: parent
            width: Theme.radio.dot
            height: Theme.radio.dot
            radius: Theme.radius.full
            color: Theme.radio.checked
            visible: root.checked
        }

        FocusRing { target: root; radius: Theme.radius.full }
    }

    contentItem: Label {
        role: "body"
        text: root.text
        leftPadding: root.indicator.width + root.spacing
        verticalAlignment: Text.AlignVCenter
    }
}
