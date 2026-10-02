import QtQuick
import qs.Commons
import qs.Ui

// A labelled control with a hint and an error line: the control goes in
// the body, `label` above it (or beside it when `inline` holds, in a
// FormRow, which owns the key/value row's geometry), `hint` under it, and
// `error` in the hint's place in the error colour while it is set. An
// inline hint starts under the value column. Width comes from the parent;
// the label, the control and the hint sit `field.paddingX` in from each
// side. The default is zero, so a field's unboxed label sits on the
// container's content edge and its control ends on that edge. `valueX` is
// where the value column starts, for content that belongs under it.
Column {
    id: root

    property string label: ""
    property string hint: ""
    property string error: ""
    property bool inline: Theme.field.inline
    default property alias control: controlRow.control
    // The width the label, the control's row and the hint share: the
    // column's own, less its padding, since a positioner does not narrow
    // its children.
    readonly property real bodyWidth: width - leftPadding - rightPadding
    readonly property real valueX: leftPadding + controlRow.valueX

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

    FormRow {
        id: controlRow
        width: root.bodyWidth
        label: root.label
        labelColumn: root.inline
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
            x: controlRow.valueX
            width: parent.width - x
            wrapMode: Text.Wrap
        }
    }
}
