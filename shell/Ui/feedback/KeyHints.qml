import QtQuick
import qs.Commons
import qs.Ui

// A single shortcut hint row. Each `hints` entry is `{ key, text }` or
// `{ keys, text }`; `key: "Left/Right"` draws two caps, while
// `key: "Ctrl+Tab"` draws one chord.
Row {
    id: root

    property var hints: []

    spacing: Theme.stack.group

    function alternatives(entry) {
        if (entry.keys !== undefined) return entry.keys;
        const key = entry.key === undefined ? "" : String(entry.key);
        return key.indexOf("/") === -1 ? [key] : key.split("/").map(part => part.trim()).filter(part => part !== "");
    }

    Repeater {
        model: root.hints

        Row {
            id: pair

            required property var modelData
            readonly property var keys: root.alternatives(modelData)

            spacing: Theme.stack.inline

            Row {
                id: caps
                spacing: Theme.space.xs
                visible: pair.keys.length > 0 && !(pair.keys.length === 1 && pair.keys[0] === "")
                Repeater {
                    model: pair.keys
                    KeyCaps { shortcut: String(modelData) }
                }
            }

            Label {
                role: "hint"
                y: topForCapCenter(Math.max(Theme.kbd.height, caps.implicitHeight))
                text: pair.modelData.text
            }
        }
    }
}
