import QtQuick
import qs.Commons
import qs.Ui

// Date and time from the shared clock, which ticks once a second only
// while a format on some screen shows seconds.
BarWidget {
    id: root
    moduleName: "vgs.clock"

    readonly property string format: String(setting("format", "ddd d MMM  HH:mm"))

    readonly property string displayed: label.text

    implicitWidth: label.implicitWidth
    implicitHeight: barSize

    // A quoted literal such as 'secs' is not a seconds field.
    readonly property bool showsSeconds: root.format.replace(/'[^']*'/g, "").indexOf("s") !== -1
    onShowsSecondsChanged: Time.holdSeconds(root, root.showsSeconds)
    Component.onCompleted: Time.holdSeconds(root, root.showsSeconds)
    Component.onDestruction: Time.holdSeconds(root, false)

    Text {
        id: label
        anchors.centerIn: parent
        text: Qt.formatDateTime(Time.now, root.format)
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.size
    }
}
