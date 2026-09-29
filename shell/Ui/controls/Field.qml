import QtQuick
import qs.Commons
import qs.Ui

// A labelled control with a hint and an error line: the control goes in
// the body, `label` above it (or beside it when `inline` holds, at the
// theme's label width and label gap), `hint` under it, and `error` in the
// hint's place in the error colour while it is set. Width comes from the
// parent; the label, the control and the hint sit `field.paddingX` in from
// each side, the edge a list item's icon starts on.
Column {
    id: root

    property string label: ""
    property string hint: ""
    property string error: ""
    property bool inline: Theme.field.inline
    property real contentPaddingX: Theme.field.paddingX
    default property alias control: slot.data
    // The width the label, the control's row and the hint share: the
    // column's own, less its padding, since a positioner does not narrow
    // its children.
    readonly property real bodyWidth: width - leftPadding - rightPadding

    leftPadding: contentPaddingX
    rightPadding: contentPaddingX
    spacing: Theme.field.gap

    Label {
        role: "label"
        text: root.label
        visible: root.label !== "" && !root.inline
        width: root.bodyWidth
        elide: Text.ElideRight
    }

    Row {
        width: root.bodyWidth
        spacing: Theme.field.labelGap

        Label {
            role: "label"
            text: root.label
            visible: root.inline
            width: Theme.field.labelWidth
            elide: Text.ElideRight
            anchors.verticalCenter: parent.verticalCenter
        }

        Item {
            id: slot
            width: parent.width - (root.inline ? Theme.field.labelWidth + parent.spacing : 0)
            height: childrenRect.height
        }
    }

    Label {
        role: "hint"
        text: root.error !== "" ? root.error : root.hint
        color: root.error !== "" ? Theme.color.danger : Theme.text.hint.color
        visible: text !== ""
        width: root.bodyWidth
        wrapMode: Text.Wrap
    }
}
