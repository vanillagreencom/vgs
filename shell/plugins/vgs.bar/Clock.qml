import QtQuick
import qs.Commons

// Date and time from the shared clock, in the bar's `clockFormat`. The
// shared clock ticks once a second only while some format on some screen
// shows seconds.
Item {
    id: root

    required property Item bar
    readonly property string format: bar.shell !== null ? String(bar.shell.settings.clockFormat) : ""
    readonly property string displayed: label.text

    // A quoted literal such as 'secs' is not a seconds field.
    readonly property bool showsSeconds: format.replace(/'[^']*'/g, "").indexOf("s") !== -1
    onShowsSecondsChanged: Time.holdSeconds(root, root.showsSeconds)
    Component.onCompleted: Time.holdSeconds(root, root.showsSeconds)
    Component.onDestruction: Time.holdSeconds(root, false)

    implicitWidth: label.implicitWidth
    implicitHeight: bar.barSize

    Text {
        id: label
        anchors.centerIn: parent
        text: Qt.formatDateTime(Time.now, root.format)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.size
    }
}
