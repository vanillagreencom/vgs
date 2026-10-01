import QtQuick
import qs.Commons
import qs.Ui
import "../foundation/KeyNavLogic.js" as Logic

Row {
    id: root

    property string shortcut: ""
    readonly property var caps: Logic.keyCaps(shortcut)

    spacing: Theme.space.sm
    visible: caps.length > 0

    Repeater {
        model: root.caps
        Kbd { text: String(modelData) }
    }
}
