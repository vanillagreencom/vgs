import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// A horizontal slider. The template owns `from`, `to`, `value`, `stepSize`
// and the arithmetic of a drag, the arrow keys and a click on the track;
// this file draws the track, the filled part and the handle. The fill is
// `position` long and starts from the right when mirrored, as the handle
// does through `visualPosition`.
T.Slider {
    id: root

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitHandleWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(implicitBackgroundHeight + topInset + bottomInset, implicitHandleHeight + topPadding + bottomPadding)
    hoverEnabled: true
    PointerCursor {}
    opacity: enabled ? 1 : Theme.opacity.disabled

    background: Rectangle {
        x: root.leftPadding
        y: root.topPadding + (root.availableHeight - height) / 2
        implicitWidth: Theme.size.panel.sm / 2
        implicitHeight: Theme.slider.track
        width: root.availableWidth
        height: implicitHeight
        radius: Theme.slider.radius
        color: Theme.slider.trackColor

        Rectangle {
            x: root.mirrored ? parent.width - width : 0
            width: root.position * parent.width
            height: parent.height
            radius: Theme.slider.radius
            color: Theme.slider.fill
        }
    }

    handle: Rectangle {
        x: root.leftPadding + root.visualPosition * (root.availableWidth - width)
        y: root.topPadding + (root.availableHeight - height) / 2
        implicitWidth: Theme.slider.handle
        implicitHeight: Theme.slider.handle
        radius: Theme.slider.radius
        color: Theme.slider.handleColor
        border.width: Theme.border.thick
        border.color: root.pressed ? Theme.slider.fill : Theme.slider.handleBorder
        FocusRing { target: root; radius: Theme.slider.radius }
    }
}
