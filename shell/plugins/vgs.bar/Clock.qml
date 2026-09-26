import QtQuick
import qs.Commons

// Date and time from the shared clock, in the bar's `clockFormat`. The
// shared clock ticks once a second only while some format on some screen
// shows seconds.
Item {
    id: root

    // The bar, read for its `shell` alone; it goes before its built-ins when
    // a screen goes away, so the read is null-checked.
    required property Item bar
    readonly property string format: bar && bar.shell !== null ? String(bar.shell.settings.clockFormat) : ""
    readonly property string displayed: label.text

    // A quoted literal such as 'secs' is not a seconds field.
    readonly property bool showsSeconds: format.replace(/'[^']*'/g, "").indexOf("s") !== -1
    onShowsSecondsChanged: Time.holdSeconds(root, root.showsSeconds)
    Component.onCompleted: Time.holdSeconds(root, root.showsSeconds)
    Component.onDestruction: Time.holdSeconds(root, false)

    implicitWidth: label.implicitWidth
    implicitHeight: Style.bar.sizeHorizontal

    Text {
        id: label
        anchors.centerIn: parent
        text: Qt.formatDateTime(Time.now, root.format)
        color: Color.bar.text
        font.family: Style.font.family
        font.pixelSize: Style.font.size
    }
}
