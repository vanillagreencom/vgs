import QtQuick
import QtQuick.Layouts
import qs.Commons

// __NAME__: a replacement bar. The core assigns `shell` and `screen` after
// creation, mounts every widget into the three section containers declared
// below and keeps them current. This file owns geometry only: where each
// section sits, its spacing, the bar's colours and font.
Item {
    id: bar

    property var shell: null
    property var screen: null

    readonly property color foreground: Color.bar.text
    readonly property color background: Color.bar.background
    readonly property color urgent: Color.urgent
    readonly property string fontFamily: Style.font.family
    readonly property string position: "top"
    readonly property bool vertical: false
    readonly property int barSize: Style.bar.sizeHorizontal

    readonly property Item leftSection: left
    readonly property Item centerSection: center
    readonly property Item rightSection: right

    RowLayout { id: left; spacing: Style.spacing.controlGap; anchors { left: parent.left; leftMargin: Style.spacing.controlPaddingX; verticalCenter: parent.verticalCenter } }
    RowLayout { id: center; spacing: Style.spacing.controlGap; anchors.centerIn: parent }
    RowLayout { id: right; spacing: Style.spacing.controlGap; anchors { right: parent.right; rightMargin: Style.spacing.controlPaddingX; verticalCenter: parent.verticalCenter } }
}
