import QtQuick
import qs.Commons
import qs.Ui

// Date and time from the shared clock, in the bar's `clockFormat`, in the
// `text.bar` role at the bar's vertical centre, where the workspace labels
// sit. The shared clock ticks once a second only while some format on some
// screen shows seconds.
Item {
    id: root

    // The bar, read for its `shell` alone; it goes before its built-ins when
    // a screen goes away, so the read is null-checked.
    required property Item bar
    readonly property string format: bar && bar.shell !== null ? String(bar.shell.settings.clockFormat) : ""

    // A quoted literal such as 'secs' is not a seconds field.
    readonly property bool showsSeconds: format.replace(/'[^']*'/g, "").indexOf("s") !== -1
    onShowsSecondsChanged: Time.holdSeconds(root, root.showsSeconds)
    Component.onCompleted: Time.holdSeconds(root, root.showsSeconds)
    Component.onDestruction: Time.holdSeconds(root, false)

    implicitWidth: label.implicitWidth
    implicitHeight: Theme.bar.height

    Label {
        id: label
        anchors.centerIn: parent
        role: "bar"
        text: Qt.formatDateTime(Time.now, root.format)
        color: Theme.bar.foreground
    }
}
