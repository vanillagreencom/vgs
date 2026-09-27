import QtQuick
import qs.Commons
import qs.Ui

// A labelled control with a hint and an error line: the control goes in
// the body, `label` above it (or beside it when `inline` holds, at the
// theme's label width), `hint` under it, and `error` in the hint's place
// in the error colour while it is set. Width comes from the parent.
Column {
    id: root

    property string label: ""
    property string hint: ""
    property string error: ""
    property bool inline: Theme.field.inline
    default property alias control: slot.data

    spacing: Theme.field.gap

    Label {
        role: "label"
        text: root.label
        visible: root.label !== "" && !root.inline
        width: parent.width
        elide: Text.ElideRight
    }

    Row {
        width: parent.width
        spacing: Theme.field.gap

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
        width: parent.width
        wrapMode: Text.Wrap
    }
}
