import QtQuick
import qs.Commons
import qs.Ui

// The one key/value row: a label column `field.labelWidth` wide, then the
// control slot, `field.labelGap` after the column, ending on the row's end
// edge. The row is `row.height` tall unless its label wraps or its control
// is taller, so every key/value row of a page shares one height. A one-line
// label is placed by capital height, a two-line label is centred, and the
// control is centred by its box. A label too long for its column wraps to a
// second line before it elides. `warning` draws a warning Badge, in
// `warningTone`, first in the value column, and the control follows it
// `stack.inline` later, so the label column and the control's end edge
// stay where they are. While `labelColumn` is false the row draws no label
// and keeps no row height: the control takes the full width at its own
// height, as a Field whose label stands above its control does. `valueX`
// is where the value column starts, for content that belongs under it.
// Width comes from the parent.
Item {
    id: root

    property string label: ""
    property string warning: ""
    property string warningTone: "warning"
    property bool labelColumn: true
    default property alias control: slot.data
    readonly property real valueX: labelColumn ? Theme.field.labelWidth + Theme.field.labelGap : 0

    // Smoke rows read this hook to verify all key/value rows use one
    // height without depending on the private tree shape.
    objectName: "fieldRow"
    implicitWidth: slot.x + slot.childrenRect.width
    implicitHeight: labelColumn ? Math.max(Theme.row.height, labelText.implicitHeight, slot.childrenRect.height) : slot.childrenRect.height

    Label {
        id: labelText
        role: "label"
        text: root.label
        visible: root.labelColumn
        width: Theme.field.labelWidth
        wrapMode: Text.Wrap
        maximumLineCount: 2
        elide: Text.ElideRight
        y: lineCount > 1 ? Math.round((root.height - implicitHeight) / 2) : topForCapCenter(root.height)
    }

    Badge {
        id: badge
        visible: root.warning !== ""
        text: root.warning
        tone: root.warningTone
        iconName: "triangle-alert"
        x: root.valueX
        y: Math.round((root.height - height) / 2)
    }

    Item {
        id: slot
        x: root.valueX + (badge.visible ? badge.width + Theme.stack.inline : 0)
        width: root.width - x
        height: childrenRect.height
        y: root.labelColumn ? Math.round((root.height - height) / 2) : 0
    }
}
