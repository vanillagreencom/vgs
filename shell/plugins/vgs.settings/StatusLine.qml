import QtQuick
import qs.Commons
import qs.Ui

// One read-only line of a Status row: `label` beside its value, `hint`
// under it, and `command`, when it names one, in a CodeLine the reader
// copies and the page never runs. The value is a Badge reading `text` in
// `tone`; with `tone` "", `text` as one line of text, in the itemHint role
// while `muted`; with neither, nothing beside the label.
Column {
    id: line

    property string label: ""
    property string hint: ""
    property string command: ""
    property string tone: ""
    property string text: ""
    property bool muted: false

    spacing: Theme.field.gap

    Field {
        width: line.width
        label: line.label
        inline: true
        hint: line.hint
        Loader {
            width: parent.width
            sourceComponent: line.tone !== "" ? badge : line.text !== "" ? plain : null
        }
    }

    CodeLine {
        x: Theme.field.paddingX + Theme.field.labelWidth + Theme.field.labelGap
        width: line.width - x - Theme.field.paddingX
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
        id: plain
        Label {
            role: line.muted ? "itemHint" : "item"
            text: line.text
            elide: Text.ElideRight
        }
    }
}
