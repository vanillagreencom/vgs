import QtQuick
import qs.Commons
import qs.Ui

// The browsers' key line: one key cap and what it does per entry of
// `hints`, `{ key, text }`, the cap `stack.inline` before its text and each
// pair `stack.group` from the next. An entry whose key is "" is a hint
// alone, such as Type to search. Each text centres by capital height on
// the height of a cap, drawn or not, so every text of the line shares one
// capital centre.
Row {
    id: root

    property var hints: []

    spacing: Theme.stack.group

    Repeater {
        model: root.hints

        Row {
            id: pair

            required property var modelData

            spacing: Theme.stack.inline

            Kbd {
                id: cap
                visible: pair.modelData.key !== ""
                text: pair.modelData.key
            }
            Label {
                role: "hint"
                y: topForCapCenter(cap.implicitHeight)
                text: pair.modelData.text
            }
        }
    }
}
