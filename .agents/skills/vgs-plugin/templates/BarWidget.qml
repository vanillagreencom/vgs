import QtQuick
import qs.Commons
import qs.Ui

// __NAME__: one item in a bar section. The core hands this widget `bar`,
// `moduleName` and `settings`; BarWidget declares them. Size the widget
// with implicitWidth and implicitHeight, compose the components of qs.Ui,
// and read every value they do not cover from Theme.
BarWidget {
    id: root

    // The manifest's `settings` carries the default, so the value is always
    // present; a settings change hands over a new `settings`.
    readonly property string label: String(settings.label)

    implicitWidth: text.implicitWidth
    implicitHeight: barSize

    Label {
        id: text
        anchors.centerIn: parent
        role: "body"
        text: root.label
        color: root.bar ? root.bar.foreground : Theme.bar.foreground
    }
}
