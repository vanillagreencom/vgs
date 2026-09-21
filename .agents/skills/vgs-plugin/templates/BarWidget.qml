import QtQuick
import qs.Commons
import qs.Ui

// __NAME__: one item in a bar section. The bar hands this widget `bar`,
// `moduleName` and `settings`; BarWidget declares them. Size the widget
// with implicitWidth and implicitHeight and read every colour from Color.
BarWidget {
    id: root
    moduleName: "__ID__"

    readonly property string label: String(setting("label", "__NAME__"))

    implicitWidth: text.implicitWidth
    implicitHeight: barSize

    Text {
        id: text
        anchors.centerIn: parent
        text: root.label
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.size
    }
}
