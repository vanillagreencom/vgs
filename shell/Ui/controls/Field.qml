import QtQuick
import qs.Commons
import qs.Ui

// A labelled control with a hint and an error line: the control goes in
// the body, `label` above it (or beside it when `inline` holds, at the
// theme's label width and label gap), `hint` under it, and `error` in the
// hint's place in the error colour while it is set. An inline row is
// exactly `row.height` tall unless its control is taller; the label is
// placed by capital height and the control is centred in that row. An
// inline hint starts under the value column. Width comes from the parent;
// the label, the control and the hint sit `field.paddingX` in from each
// side. The default is zero, so a field's unboxed label sits on the
// container's content edge and its control ends on that edge. An inline
// label too long for its column wraps to a second line before it elides.
// `valueX` is where the value column starts, for content that belongs under it.
Column {
    id: root

    property string label: ""
    property string hint: ""
    property string error: ""
    property bool inline: Theme.field.inline
    default property alias control: slot.data
    // The width the label, the control's row and the hint share: the
    // column's own, less its padding, since a positioner does not narrow
    // its children.
    readonly property real bodyWidth: width - leftPadding - rightPadding
    readonly property real valueX: leftPadding + (inline ? Theme.field.labelWidth + Theme.field.labelGap : 0)

    leftPadding: Theme.field.paddingX
    rightPadding: Theme.field.paddingX
    spacing: Theme.field.gap

    Label {
        role: "label"
        text: root.label
        visible: root.label !== "" && !root.inline
        width: root.bodyWidth
        elide: Text.ElideRight
    }

    Row {
        id: controlRow
        // Smoke rows read this hook to verify all key/value rows use one
        // height without depending on the private tree shape.
        objectName: "fieldRow"
        width: root.bodyWidth
        height: root.inline ? Math.max(Theme.row.height, inlineLabel.implicitHeight, slot.childrenRect.height) : slot.childrenRect.height
        spacing: Theme.field.labelGap

        Label {
            id: inlineLabel
            role: "label"
            text: root.label
            visible: root.inline
            width: Theme.field.labelWidth
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            y: !root.inline ? 0 : lineCount > 1 ? Math.round((controlRow.height - implicitHeight) / 2) : topForCapCenter(controlRow.height)
        }

        Item {
            id: slot
            width: parent.width - (root.inline ? Theme.field.labelWidth + parent.spacing : 0)
            height: childrenRect.height
            y: root.inline ? Math.round((controlRow.height - height) / 2) : 0
        }
    }

    Item {
        id: hintSlot
        visible: hintLine.text !== ""
        width: root.bodyWidth
        height: hintLine.implicitHeight

        Label {
            id: hintLine
            role: "hint"
            text: root.error !== "" ? root.error : root.hint
            color: root.error !== "" ? Theme.color.danger : Theme.text.hint.color
            x: root.inline ? Theme.field.labelWidth + Theme.field.labelGap : 0
            width: parent.width - x
            wrapMode: Text.Wrap
        }
    }
}
