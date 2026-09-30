import QtQuick
import qs.Commons
import qs.Ui
import "UpdatesLogic.js" as Logic

// The Updates icon in the bar. It draws the status the service publishes
// and runs nothing itself: a calm icon when every source is current, the
// accent tone with the pending count when updates wait, the warning tone
// when the check failed, a source failed or the check is stale, and a
// spinner while a check runs (UpdatesLogic.widgetView decides). The
// `hideWhenCurrent` setting hides it only while the last check succeeded
// and nothing waits. A left click opens or closes the flyout under it; a
// middle click opens the `update` TUI for every source. The tooltip lists
// each source's count and when the last check ran. It is one BarItem, the
// count drawn beside the icon in the icon's tone.
BarWidget {
    id: root

    readonly property var values: shell === null ? ({}) : shell.status.values
    readonly property var view: Logic.widgetView(values, setting("hideWhenCurrent", false))
    readonly property string tooltip: Logic.widgetTooltip(values, Time.now.getTime(), formatWhen)

    visible: !view.hidden
    implicitWidth: button.implicitWidth
    implicitHeight: barSize

    // The time of MS in the locale's short format, with the date when
    // WITHDATE holds.
    function formatWhen(ms, withDate) {
        const when = new Date(ms);
        return withDate ? when.toLocaleString(Qt.locale(), Locale.ShortFormat) : when.toLocaleTimeString(Qt.locale(), Locale.ShortFormat);
    }

    function toneColor(tone) {
        switch (tone) {
        case "calm": return Theme.bar.foreground;
        case "accent": return Theme.color.accent;
        case "warning": return Theme.color.warning;
        default: throw new Error("updates widget: tone " + JSON.stringify(tone) + " is not one of calm, accent, warning");
        }
    }

    // Open or close the flyout under this widget; answers the panel host's
    // reply.
    function toggle() {
        const reply = shell.surfaces.toggle("panel", "{}", root);
        if (reply !== "ok") console.warn("updates widget: panel " + reply);
        return reply;
    }

    // Open the TUI that updates every source; answers the capability's
    // reply.
    function updateAll() {
        const request = Logic.tuiRequest("all");
        const reply = shell.tui.run(request.name, request.args);
        if (reply !== "ok") console.warn("updates widget: " + reply);
        return reply;
    }

    BarItem {
        id: button
        anchors.centerIn: parent
        label: "Updates"
        iconName: root.view.icon
        spinning: root.view.spinning
        count: root.view.badge
        tone: root.toneColor(root.view.tone)
        onClicked: root.toggle()

        // pointer-cursor-exempt: it adds the middle click to the Button it sits in, whose own PointerCursor shows the hand
        TapHandler {
            acceptedButtons: Qt.MiddleButton
            onTapped: root.updateAll()
        }
        Tooltip { text: root.tooltip }
    }
}
