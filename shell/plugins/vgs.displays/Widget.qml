import QtQuick
import qs.Commons
import qs.Ui
import "DisplaysLogic.js" as Logic

// The brightness item in the bar. Each bar's widget controls the display
// on its own screen (`screens.current`): a scroll moves it one
// `brightnessStep` a notch and shows the on-screen display there, and a
// click opens the flyout under it. It hides while no ready display lights
// its screen. It reads the status the service publishes and asks the
// service's `set` for a change; it runs nothing itself, and takes no
// focus, as every bar item.
BarWidget {
    id: widget

    readonly property var values: shell === null ? ({}) : shell.status.values
    readonly property var items: values.displays === undefined ? [] : values.displays.items
    readonly property string screenName: shell === null || shell.screens.current === null ? "" : shell.screens.current.name
    // This screen's display, or null.
    readonly property var display: Logic.displayOn(items, screenName)
    readonly property int step: setting("brightnessStep", 5)
    // Wheel angle not yet turned into a step: a touchpad scrolls in parts
    // of a notch.
    property real wheelRest: 0

    visible: display !== null
    implicitWidth: visible ? button.implicitWidth : 0
    implicitHeight: barSize

    // Open or close the flyout under this widget; answers the panel host's
    // reply.
    function toggle() {
        const reply = shell.surfaces.toggle("panel", "{}", widget);
        if (reply !== "ok") console.warn("displays widget: panel " + reply);
        return reply;
    }

    // Move this screen's display NOTCHES steps, up for a positive count;
    // answers the service's reply.
    function scroll(notches) {
        if (display === null || notches === 0) return "refused: scroll=none";
        const percent = Logic.scrollTarget(display.percent, notches, step);
        const reply = shell.ipc.call("set", JSON.stringify({ id: display.id, percent: percent, osd: true }));
        if (reply !== "ok") console.warn("displays widget: " + reply);
        return reply;
    }

    BarItem {
        id: button
        anchors.centerIn: parent
        label: "Brightness"
        iconName: "sun"
        tooltip: widget.display === null ? "" : widget.display.label + " " + widget.display.percent + "%"
        onClicked: widget.toggle()

        // keyboard-path: the brightness keys and the flyout's slider change the same display
        // pointer-cursor-exempt: it adds the wheel to the BarItem it sits in, whose own PointerCursor shows the hand
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: event => {
                widget.wheelRest += event.angleDelta.y / 120;
                const notches = widget.wheelRest > 0 ? Math.floor(widget.wheelRest) : Math.ceil(widget.wheelRest);
                widget.wheelRest -= notches;
                widget.scroll(notches);
            }
        }
    }
}
