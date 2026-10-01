import QtQuick
import qs.Commons
import qs.Ui
import "ViewLogic.js" as View

// The Agent Warden shield in the bar: one icon in the tone of the state
// the service publishes as `detail`, an optional count, and a tooltip
// sentence. A click opens or closes the flyout under it. Entering Working
// pulses the shield once. With `hideWhenIdle` the widget takes no room
// while no agent runs and all is good. It is one BarItem, the count drawn
// beside the shield in its tone.
BarWidget {
    id: widget

    // The service's last derived state, null before it published one.
    readonly property var detail: shell === null || shell.status.values.detail === undefined ? null : shell.status.values.detail
    readonly property var view: View.widget(detail, Time.now.getTime(), setting("showCount", true))
    readonly property bool hidden: setting("hideWhenIdle", false) && View.idle(detail)
    readonly property string wardenState: detail === null ? "" : detail.state
    readonly property color tone: Theme.badge.tone[view.tone].foreground
    readonly property string shortcut: shell !== null && shell.shortcut !== undefined && shell.shortcut.keys !== undefined
        ? (shell.shortcut.keys.toggle || "")
        : ""

    visible: !hidden
    implicitWidth: hidden ? 0 : item.implicitWidth
    implicitHeight: barSize

    onWardenStateChanged: if (wardenState === "working") pulse.restart()

    // Open or close the flyout under this widget; answers the panel host's
    // reply.
    function toggle() {
        const reply = shell.surfaces.toggle("panel", "{}", widget);
        if (reply !== "ok") console.warn("agent-warden: widget panel " + reply);
        return reply;
    }

    BarItem {
        id: item
        anchors.centerIn: parent
        label: "Agent Warden"
        iconName: widget.view.icon
        count: widget.view.count
        tone: widget.tone
        tooltip: widget.view.tooltip
        shortcut: widget.shortcut
        onClicked: widget.toggle()
    }

    SequentialAnimation {
        id: pulse
        NumberAnimation { target: item.contentItem; property: "opacity"; to: Theme.opacity.disabled; duration: Theme.motion.duration.slow; easing.type: Theme.motion.easing.standard }
        NumberAnimation { target: item.contentItem; property: "opacity"; to: 1; duration: Theme.motion.duration.slow; easing.type: Theme.motion.easing.standard }
    }
}
