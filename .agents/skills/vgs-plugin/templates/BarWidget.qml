import QtQuick
import qs.Commons
import qs.Ui

// __NAME__: one item in a bar section. The core hands this widget `bar`,
// `moduleName` and `settings`; BarWidget declares them. Size the widget
// with implicitWidth and implicitHeight and read every colour from Color.
BarWidget {
    id: root

    // The manifest's `settings` carries the default, so the value is always
    // present; a settings change hands over a new `settings`.
    readonly property string label: String(settings.label)

    implicitWidth: text.implicitWidth
    implicitHeight: barSize

    Text {
        id: text
        anchors.centerIn: parent
        text: root.label
        color: root.bar ? root.bar.foreground : Color.bar.text
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.size
    }
}
