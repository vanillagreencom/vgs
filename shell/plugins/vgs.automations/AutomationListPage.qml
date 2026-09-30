import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

FocusScope {
    id: page

    required property Item panel
    property int current: 0
    readonly property var rows: panel.automations

    signal newRequested()
    signal templateRequested(string key)
    signal openRequested(string id)
    signal duplicateRequested(string id)
    signal removeRequested(string id)
    signal runRequested(string id)
    signal toggleRequested(string id, bool enabled)

    focus: true

    function focusList() { forceActiveFocus(); }
    function clamp() { current = Math.max(0, Math.min(current, rows.length - 1)); }
    function move(step) {
        if (rows.length === 0) return;
        plate.disarm();
        current = Math.max(0, Math.min(rows.length - 1, current + step));
        reveal(current);
    }
    function reveal(index) {
        const item = listItems.itemAt(index);
        if (item === null) return;
        const top = item.mapToItem(layout.scrollArea.contentItem, 0, 0).y;
        if (top < layout.scrollArea.contentY) layout.scrollArea.contentY = top;
        else if (top + item.height > layout.scrollArea.contentY + layout.scrollArea.height) layout.scrollArea.contentY = top + item.height - layout.scrollArea.height;
    }
    function currentId() { return rows.length === 0 ? "" : rows[current].id; }
    function openCurrent() { const id = currentId(); if (id !== "") openRequested(id); }
    function toggleCurrent() { const id = currentId(); if (id !== "") toggleRequested(id, !rows[current].enabled); }
    function removeCurrent() { const id = currentId(); if (id !== "") removeRequested(id); }

    onRowsChanged: { plate.disarm(); plate.snap(); clamp(); }

    Keys.onUpPressed: move(-1)
    Keys.onDownPressed: move(1)
    Keys.onReturnPressed: openCurrent()
    Keys.onEnterPressed: openCurrent()
    Keys.onSpacePressed: toggleCurrent()
    Keys.onDeletePressed: removeCurrent()
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Home || event.key === Qt.Key_End) {
            move(event.key === Qt.Key_Home ? -rows.length : rows.length);
            event.accepted = true;
        }
    }

    ListCursor { id: plate; parent: listColumn }

    Pane {
        id: layout
        anchors.fill: parent
        container: "window"
        bodySpacing: 0

        header: [
            PageHeader {
                width: layout.contentWidth
                text: "Automations"
                trailing: [
                    Row {
                        spacing: Theme.space.xs
                        anchors.verticalCenter: parent.verticalCenter
                        Button {
                            id: newButton
                            text: "New"
                            iconName: "plus"
                            size: "sm"
                            variant: "primary"
                            onClicked: page.newRequested()
                            Menu {
                                id: templateMenu
                                MenuItem { text: "Blank automation"; iconName: "plus"; onTriggered: page.newRequested() }
                                Repeater {
                                    model: panel.templates
                                    MenuItem {
                                        required property var modelData
                                        text: modelData.label
                                        iconName: "copy-plus"
                                        onTriggered: page.templateRequested(modelData.key)
                                    }
                                }
                            }
                        }
                        IconButton { iconName: "chevron-down"; label: "New from template"; size: "sm"; onClicked: templateMenu.toggle() }
                    }
                ]
            }
        ]

        Item {
            width: parent.width
            height: listColumn.implicitHeight

            Column {
                id: listColumn
                width: parent.width
                spacing: Theme.stack.row

                Label {
                    width: parent.width
                    role: "hint"
                    text: "No automations yet. Create a blank automation or start from a template."
                    visible: page.rows.length === 0
                    wrapMode: Text.Wrap
                }

                Repeater {
                    id: listItems
                    model: ScriptModel { values: page.rows; objectProp: "id" }
                    AutomationRow {
                        required property var modelData
                        required property int index
                        row: modelData
                        width: parent.width
                        highlighted: index === page.current
                        cursorItem: plate
                        onPointed: page.current = index
                        onOpenRequested: page.openRequested(modelData.id)
                        onDuplicateRequested: page.duplicateRequested(modelData.id)
                        onRemoveRequested: page.removeRequested(modelData.id)
                        onRunRequested: page.runRequested(modelData.id)
                        onToggleRequested: enabled => page.toggleRequested(modelData.id, enabled)
                    }
                }
            }
        }
    }
}
