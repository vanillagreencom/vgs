import QtQuick
import qs.Commons
import qs.Ui

// One read-only line of a Status row: `label` beside its value, `hint`
// under it, and `command`, when it names one, in a CodeLine the reader
// copies and the page never runs. The value is a Badge reading `text` in
// `tone`; with `tone` "", `text` as one line of text, in the itemHint role
// while `muted`; with neither, the hint itself on the label's row, so a
// line that names a group never leaves its value column empty.
Column {
    id: line

    property string label: ""
    property string hint: ""
    property string command: ""
    property string tone: ""
    property string text: ""
    property bool muted: false

    spacing: Theme.field.gap

    readonly property bool valued: tone !== "" || text !== ""

    Field {
        id: field
        width: line.width
        label: line.label
        inline: true
        hint: line.valued ? line.hint : ""
        Loader {
            width: parent.width
            sourceComponent: line.tone !== "" ? badge : line.text !== "" ? plain : line.hint !== "" ? hintValue : null
        }
    }

    CodeLine {
        x: field.valueX
        width: line.width - x - field.rightPadding
        visible: line.command !== ""
        text: line.command
        copyLabel: "Copy the command"
    }

    Component {
        id: badge
        Item {
            implicitHeight: chip.height
            Badge { id: chip; text: line.text; tone: line.tone }
        }
    }

    Component {
        id: hintValue
        Label {
            role: "hint"
            text: line.hint
            wrapMode: Text.Wrap
        }
    }

    Component {
        id: plain
        Label {
            role: line.muted ? "itemHint" : "item"
            text: line.text
            elide: Text.ElideRight
        }
    }
}
