import QtQuick
import qs.Commons
import qs.Ui

// An on-screen display of one level, such as the volume or a display's
// brightness, for a passive layer: an icon, a ProgressBar `osd.barWidth`
// long filled to `level`, and a label, `osd.gap` apart and `osd.padding`
// inside a raised card. `level` is a share of one, held to 0 to 1, and a
// level that is not a number draws empty. `text` reads the level as a
// percentage unless the caller names it, such as a device's name or Muted;
// a muted level passes its own `iconName` and `text`. The label column is
// as wide as "100%" or the text, whichever is wider, up to
// `osd.labelMaxWidth`, where the text elides, so the bar keeps its place
// while the level changes. It takes no focus and no pointer input; the
// layer that shows it places it.
Rectangle {
    id: root

    property string iconName: ""
    property real level: 0
    readonly property real bounded: Number.isFinite(level) ? Math.max(0, Math.min(1, level)) : 0
    property string text: Math.round(bounded * 100) + "%"

    implicitWidth: 2 * Theme.osd.padding + content.width
    implicitHeight: 2 * Theme.osd.padding + content.height
    radius: Theme.osd.radius
    color: Theme.osd.background
    border.width: Theme.border.thin
    border.color: Theme.osd.border
    Accessible.role: Accessible.ProgressBar
    Accessible.name: text

    Row {
        id: content
        x: Theme.osd.padding
        y: Theme.osd.padding
        height: Math.max(icon.height, bar.height, label.lineBox)
        spacing: Theme.osd.gap

        Icon {
            id: icon
            visible: root.iconName !== ""
            name: root.iconName
            size: Theme.osd.icon
            color: Theme.color.text
            anchors.verticalCenter: parent.verticalCenter
        }

        ProgressBar {
            id: bar
            width: Theme.osd.barWidth
            value: root.bounded
            anchors.verticalCenter: parent.verticalCenter
        }

        Item {
            width: Math.min(Theme.osd.labelMaxWidth, Math.max(label.implicitWidth, widest.implicitWidth))
            height: parent.height

            Label { id: widest; visible: false; role: "item"; text: "100%" }
            Label {
                id: label
                role: "item"
                text: root.text
                width: parent.width
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
                y: topForCapCenter(parent.height)
            }
        }
    }
}
