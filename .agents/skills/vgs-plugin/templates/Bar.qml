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

    readonly property color foreground: Color.bar.text
    readonly property color background: Color.bar.background
    readonly property string fontFamily: Style.font.family
    readonly property int barSize: Style.bar.sizeHorizontal

    readonly property Item leftSection: left
    readonly property Item centerSection: center
    readonly property Item rightSection: right

    RowLayout { id: left; spacing: Style.spacing.lg; anchors { left: parent.left; leftMargin: Style.spacing.xl; top: parent.top; bottom: parent.bottom } }
    RowLayout { id: center; spacing: Style.spacing.lg; anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; bottom: parent.bottom } }
    RowLayout { id: right; spacing: Style.spacing.lg; anchors { right: parent.right; rightMargin: Style.spacing.xl; top: parent.top; bottom: parent.bottom } }
}
