import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// A horizontal slider. The template owns `from`, `to`, `value`, `stepSize`
// and the arithmetic of a drag, the arrow keys and a click on the track;
// this file draws the track, the filled part and the handle. The fill is
// `position` long and starts from the right when mirrored, as the handle
// does through `visualPosition`. The control is never shorter than
// `size.control.sm`, so the thin track keeps a larger input area.
T.Slider {
    id: root

    property real pageStep: stepSize > 0 ? stepSize * 5 : Math.abs(to - from) / 20
    property bool focusPreview: false

    function clamp(value) {
        return Math.max(Math.min(from, to), Math.min(Math.max(from, to), value));
    }

    function snap(value) {
        if (stepSize <= 0) return value;
        const low = Math.min(from, to);
        const steps = Math.round((value - low) / stepSize);
        return clamp(low + steps * stepSize);
    }

    function commit(value) {
        root.value = snap(clamp(value));
        root.moved();
    }

    implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset, implicitHandleWidth + leftPadding + rightPadding)
    implicitHeight: Math.max(Theme.size.control.sm, implicitBackgroundHeight + topInset + bottomInset, implicitHandleHeight + topPadding + bottomPadding)
    hoverEnabled: true
    PointerCursor {}
    opacity: enabled ? 1 : Theme.opacity.disabled
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Up) commit(value + (stepSize > 0 ? stepSize : pageStep));
        else if (event.key === Qt.Key_Down) commit(value - (stepSize > 0 ? stepSize : pageStep));
        else if (event.key === Qt.Key_Home) commit(from);
        else if (event.key === Qt.Key_End) commit(to);
        else if (event.key === Qt.Key_PageUp) commit(value + pageStep);
        else if (event.key === Qt.Key_PageDown) commit(value - pageStep);
        else {
            event.accepted = false;
            return;
        }
        event.accepted = true;
    }

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
        FocusRing { target: root }
    }
}
