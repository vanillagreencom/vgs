import QtQuick
import qs.Commons
import qs.Ui
import "ViewLogic.js" as View

// The Agent Warden shield in the bar: one icon in the tone of the state
// the service publishes as `detail`, an optional count, and a tooltip
// sentence. A click opens or closes the flyout under it. Entering Working
// pulses the shield once. With `hideWhenIdle` the widget takes no room
// while no agent runs and all is good.
BarWidget {
    id: root

    // The service's last derived state, null before it published one.
    readonly property var detail: shell === null || shell.status.values.detail === undefined ? null : shell.status.values.detail
    readonly property var view: View.widget(detail, Time.now.getTime(), setting("showCount", true))
    readonly property bool hidden: setting("hideWhenIdle", false) && View.idle(detail)
    readonly property string wardenState: detail === null ? "" : detail.state
    readonly property color tone: Theme.badge.tone[view.tone].foreground

    visible: !hidden
    implicitWidth: hidden ? 0 : content.implicitWidth + 2 * Theme.bar.item.paddingX
    implicitHeight: barSize

    onWardenStateChanged: if (wardenState === "working") pulse.restart()

    // Open or close the flyout under this widget; answers the panel host's
    // reply.
    function toggle() {
        const reply = shell.surfaces.toggle("panel", "{}", root);
        if (reply !== "ok") console.warn("agent-warden: widget panel " + reply);
        return reply;
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: Theme.bar.item.iconGap

        Icon {
            id: shield
            anchors.verticalCenter: parent.verticalCenter
            name: root.view.icon
            size: Theme.icon.size.md
            color: root.tone
        }
        Label {
            anchors.verticalCenter: parent.verticalCenter
            role: "bar"
            visible: text !== ""
            text: root.view.count
            color: root.tone
        }
    }

    SequentialAnimation {
        id: pulse
        NumberAnimation { target: shield; property: "opacity"; to: Theme.opacity.disabled; duration: Theme.motion.duration.slow; easing.type: Theme.motion.easing.standard }
        NumberAnimation { target: shield; property: "opacity"; to: 1; duration: Theme.motion.duration.slow; easing.type: Theme.motion.easing.standard }
    }

    MouseArea {
        anchors.fill: parent
        PointerCursor {}
        onClicked: root.toggle()
    }

    Tooltip { text: root.view.tooltip }
}
