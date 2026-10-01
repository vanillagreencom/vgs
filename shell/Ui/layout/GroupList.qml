import QtQuick
import qs.Commons
import qs.Ui

// A column of groups: each child is one group of lines, such as a key/value
// row with its hint, its action and its command, whose own lines sit
// `row.lineGap` apart. Groups sit `groupList.gap` apart with a hairline in
// `groupList.divider` centred in each gap, so the lines of one group read
// as one block and the next group starts clearly after it. A child that is
// hidden or has no width or height takes no gap and no hairline, as a
// Column skips it. A group list inside another is one group of the outer
// one and divides its own groups the same way, so every group of a section
// is divided alike whatever holds it.
Item {
    id: root

    default property alias groups: column.data
    // The y of each hairline, one per gap between two shown groups.
    readonly property var hairlines: {
        const shown = column.children.filter(child => child.visible && child.width > 0 && child.height > 0);
        return shown.slice(1).map(child => Math.round(child.y - (Theme.groupList.gap + Theme.divider.thickness) / 2));
    }

    width: parent ? parent.width : implicitWidth
    implicitWidth: column.implicitWidth
    implicitHeight: column.implicitHeight

    Column {
        id: column
        width: root.width
        spacing: Theme.groupList.gap
    }

    Repeater {
        model: root.hairlines
        Divider {
            required property real modelData
            y: modelData
            width: root.width
            color: Theme.groupList.divider
        }
    }
}
