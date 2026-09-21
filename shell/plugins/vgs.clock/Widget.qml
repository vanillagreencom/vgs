import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Date and time. The clock ticks once a minute unless the format shows
// seconds, so an idle bar does no work it does not display.
BarWidget {
    id: root
    moduleName: "vgs.clock"

    readonly property string format: String(setting("format", "ddd d MMM  HH:mm"))

    implicitWidth: label.implicitWidth
    implicitHeight: barSize

    SystemClock {
        id: clock
        precision: root.format.indexOf("s") !== -1 ? SystemClock.Seconds : SystemClock.Minutes
    }

    Text {
        id: label
        anchors.centerIn: parent
        text: Qt.formatDateTime(clock.date, root.format)
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.size
    }
}
