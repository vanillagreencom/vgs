import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "AutomationsViewLogic.js" as View

Section {
    id: root

    property string summary: ""
    property var occurrences: []
    property int current: 0

    width: parent ? parent.width : implicitWidth
    title: "Next runs"
    description: "The engine judges the next five occurrences."
    headerInset: 0
    rowSpacing: Theme.stack.row

    onOccurrencesChanged: {
        plate.disarm();
        plate.snap();
        current = Math.max(0, Math.min(current, occurrences.length - 1));
    }

    Label {
        width: root.width
        role: "bodyStrong"
        text: root.summary
        wrapMode: Text.Wrap
    }

    Item {
        width: root.width
        height: previewColumn.implicitHeight

        // The cursor sits in this item, beside the rows' column: a
        // positioner would lay the plate out as a row.
        ListCursor { id: plate }
        Column {
            id: previewColumn
            width: parent.width
            spacing: Theme.stack.row
            Repeater {
                model: ScriptModel { values: root.occurrences }
                ListItem {
                    required property var modelData
                    required property int index
                    width: previewColumn.width
                    iconName: "clock"
                    text: View.formatWhen(modelData)
                    highlighted: index === root.current
                    cursor: plate
                    onPointed: root.current = index
                    onClicked: root.current = index
                }
            }
            Label {
                width: parent.width
                role: "hint"
                text: "No future run matches this draft."
                visible: root.occurrences.length === 0
                wrapMode: Text.Wrap
            }
        }
    }
}
