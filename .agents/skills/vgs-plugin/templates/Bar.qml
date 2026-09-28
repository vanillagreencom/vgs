import QtQuick
import QtQuick.Layouts
import qs.Commons

// __NAME__: a replacement bar. The core assigns `shell` and `screen` after
// creation, mounts every plugin widget into the three section containers
// declared below and keeps them current. This file owns their geometry:
// where each section sits, its spacing, the bar's colours and font. Each
// container spans the bar's height so a widget is centred in it.
Item {
    id: bar

    property var shell: null
    property var screen: null

    readonly property color foreground: Theme.bar.foreground
    readonly property color background: Theme.bar.background
    readonly property string fontFamily: Theme.text.bar.family
    readonly property int barSize: Theme.bar.height

    readonly property Item leftSection: left
    readonly property Item centerSection: center
    readonly property Item rightSection: right

    RowLayout { id: left; spacing: Theme.bar.gap; anchors { left: parent.left; leftMargin: Theme.bar.padding; top: parent.top; bottom: parent.bottom } }
    RowLayout { id: center; spacing: Theme.bar.gap; anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; bottom: parent.bottom } }
    RowLayout { id: right; spacing: Theme.bar.gap; anchors { right: parent.right; rightMargin: Theme.bar.padding; top: parent.top; bottom: parent.bottom } }
}
