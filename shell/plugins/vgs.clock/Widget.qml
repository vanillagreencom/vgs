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

    // Seconds tick only when a seconds field is shown; a quoted literal
    // such as 'secs' is not a field.
    readonly property bool showsSeconds: root.format.replace(/'[^']*'/g, "").indexOf("s") !== -1

    SystemClock {
        id: clock
        precision: root.showsSeconds ? SystemClock.Seconds : SystemClock.Minutes
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
