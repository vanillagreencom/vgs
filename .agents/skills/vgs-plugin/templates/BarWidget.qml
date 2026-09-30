import QtQuick
import qs.Commons
import qs.Ui

// __NAME__: one item in a bar section. The core hands this widget `bar`,
// `moduleName` and `settings`; BarWidget declares them. The widget draws
// one BarItem, as every first-party widget does, so its height, padding,
// icon and text match the bar's other items; give it `iconName`, `text`
// or `count`, and `tone` from the bar's colour.
BarWidget {
    id: root

    // The manifest's `settings` carries the default, so the value is always
    // present; a settings change hands over a new `settings`.
    readonly property string label: String(settings.label)

    implicitWidth: item.implicitWidth
    implicitHeight: barSize

    BarItem {
        id: item
        anchors.centerIn: parent
        text: root.label
        tone: root.bar ? root.bar.foreground : Theme.bar.foreground
    }
}
