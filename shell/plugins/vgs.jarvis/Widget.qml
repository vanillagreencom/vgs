import QtQuick
import qs.Commons
import qs.Ui
import "WidgetView.js" as View

// The Jarvis icon in the bar. It draws the status the service publishes
// and runs nothing itself: one icon and tone for live, problem, off,
// muted, working and ready (WidgetView.view decides), and a tooltip that
// names the state and what a click does. A click, Space (which the button
// turns into a click), Return and keypad Enter call the service's `mute`
// IPC handler, the intent the Mute key sends. It is one BarItem.
BarWidget {
    id: root

    readonly property var view: View.view(shell === null ? ({}) : shell.status.values)

    implicitWidth: item.implicitWidth
    implicitHeight: barSize

    function toneColor(tone) {
        switch (tone) {
        case "calm": return Theme.bar.foreground;
        case "accent": return Theme.badge.tone.accent.foreground;
        case "info": return Theme.badge.tone.info.foreground;
        case "danger": return Theme.badge.tone.danger.foreground;
        case "neutral": return Theme.badge.tone.neutral.foreground;
        default: throw new Error("jarvis widget: tone " + JSON.stringify(tone) + " is not one of calm, accent, info, danger, neutral");
        }
    }

    // Toggle privacy mute through the service; answers the handler's reply.
    function toggleMute() {
        const reply = shell.ipc.call("mute", "");
        if (reply !== "ok") console.warn("jarvis widget: mute " + reply);
        return reply;
    }

    BarItem {
        id: item
        anchors.centerIn: parent
        label: "Jarvis"
        iconName: root.view.icon
        tone: root.toneColor(root.view.tone)
        tooltip: root.view.tooltip
        onClicked: root.toggleMute()
    }
}
