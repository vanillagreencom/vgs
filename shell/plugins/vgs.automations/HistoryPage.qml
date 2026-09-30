import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

FocusScope {
    id: page

    required property Item panel
    property string filterId: ""
    property int current: 0
    readonly property var filterOptions: [{ id: "", label: "All automations" }].concat(panel.automations.map(a => ({ id: a.id, label: a.name })))
    readonly property var groups: panel.filteredHistoryGroups(filterId)
    readonly property var flatRows: {
        let out = [];
        for (const group of groups) out = out.concat(group.rows);
        return out;
    }

    signal clearRequested(string id)
    signal openRequested(string transcript)

    focus: true

    function filterIndex() {
        const ids = filterOptions.map(option => option.id);
        return Math.max(0, ids.indexOf(filterId));
    }
    function move(step) {
        if (flatRows.length === 0) return;
        plate.disarm();
        current = Math.max(0, Math.min(flatRows.length - 1, current + step));
    }
    function openCurrent() { if (flatRows.length > 0) openRequested(flatRows[current].transcript); }

    onFlatRowsChanged: { plate.disarm(); plate.snap(); current = Math.max(0, Math.min(current, flatRows.length - 1)); }

    Keys.onUpPressed: move(-1)
    Keys.onDownPressed: move(1)
    Keys.onReturnPressed: openCurrent()
    Keys.onEnterPressed: openCurrent()
    Keys.onDeletePressed: clearRequested(filterId)
    Keys.onEscapePressed: event => { event.accepted = false; }

    Pane {
        id: layout
        anchors.fill: parent
        container: "window"
        bodySpacing: Theme.stack.group

        header: [
            PageHeader {
                width: layout.contentWidth
                text: "History"
                trailing: [
                    Button { text: "Clear history"; iconName: "trash"; size: "sm"; variant: "danger"; anchors.verticalCenter: parent.verticalCenter; onClicked: page.clearRequested(page.filterId) }
                ]
            }
        ]

        Field {
            width: parent.width
            label: "Automation"
            inline: true
            Select {
                width: parent.width
                model: page.filterOptions
                textRole: "label"
                currentIndex: page.filterIndex()
                onCurrentIndexChanged: page.filterId = page.filterOptions[currentIndex].id
            }
        }

        Item {
            width: parent.width
            height: historyColumn.implicitHeight

            ListCursor { id: plate; parent: historyColumn }
            Column {
                id: historyColumn
                width: parent.width
                spacing: Theme.stack.group

                Label {
                    width: parent.width
                    role: "hint"
                    text: "No runs from the last 30 days."
                    visible: page.groups.length === 0
                    wrapMode: Text.Wrap
                }

                Repeater {
                    model: page.groups
                    Section {
                        required property var modelData
                        width: historyColumn.width
                        title: modelData.label
                        headerInset: 0
                        Repeater {
                            model: modelData.rows
                            HistoryRow {
                                required property var modelData
                                required property int index
                                readonly property int absoluteIndex: page.flatRows.indexOf(modelData)
                                width: parent.width
                                row: modelData
                                highlighted: absoluteIndex === page.current
                                cursorItem: plate
                                scrollArea: layout.scrollArea
                                onPointed: page.current = absoluteIndex
                                onOpenRequested: transcript => page.openRequested(transcript)
                            }
                        }
                    }
                }
            }
        }
    }
}
