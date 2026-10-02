import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The System window's sidebar: a search field, then every enabled section
// under the heading of its group, in the order the panes capability lists
// them, then the Shell & Plugins row at the foot. The rows are one list
// with one ListCursor: Up, Down, Home, End and the pages move it, a letter
// jumps to the next row whose name starts with the letters typed so far,
// and a hover moves it once the pointer moves. Enter or Right on a section
// enters it and on Shell & Plugins opens the Settings window, as a click
// does. Ctrl+F reaches the search field from anywhere in the window (the
// window owns that key); there Up, Down and Enter still move and enter,
// and Escape clears the query, then returns to the rows.
FocusScope {
    id: page

    // The System window: its sections, the shown section and the steps.
    required property Item panel
    property string query: ""
    // The index of the selected entry: a section of `shown`, or
    // `shown.length` for Shell & Plugins.
    property int current: 0

    // The sections whose name or id holds the query, in the list's order.
    readonly property var shown: {
        const wanted = query.trim().toLowerCase();
        return panel.panes.filter(p => wanted === "" || [p.name, p.id].some(t => String(t).toLowerCase().indexOf(wanted) !== -1));
    }
    // The groups of `shown`, each once, in the order their first section
    // comes; the capability sorts by group, so a group's sections are
    // consecutive.
    readonly property var groups: {
        const out = [];
        for (const row of shown)
            if (out.length === 0 || out[out.length - 1].name !== row.group) out.push({ name: row.group });
        return out;
    }
    readonly property int footerIndex: shown.length
    readonly property alias scrollArea: layout.scrollArea
    readonly property alias searchField: search
    // The item that holds the keys while the rows have them.
    readonly property alias rows: list

    // The rows change under a resting pointer: it takes no row until it
    // moves, and the cursor lands on the row the keyboard keeps.
    onShownChanged: {
        plate.disarm();
        plate.snap();
        current = Math.max(0, Math.min(current, footerIndex));
    }

    // A new query selects its first match.
    onQueryChanged: current = 0

    function focusRows(reason) { list.forceActiveFocus(reason === undefined ? Qt.TabFocusReason : reason); }
    function focusSearch(reason) { search.forceActiveFocus(reason === undefined ? Qt.TabFocusReason : reason); }

    // Select the section `id` when the list shows it.
    function select(id) {
        const index = shown.findIndex(p => p.id === id);
        if (index !== -1) current = index;
    }

    function labelAt(index) {
        return index === footerIndex ? footer.text : index >= 0 && index < shown.length ? shown[index].name : "";
    }

    // The row item of entry `index`, for the cursor's reveal.
    function itemAt(index) {
        if (index === footerIndex) return footer;
        for (let g = 0; g < sections.count; g++) {
            const section = sections.itemAt(g);
            if (section === null) continue;
            for (let r = 0; r < section.rowCount; r++) {
                const item = section.rowAt(r);
                if (item !== null && item.entryIndex === index) return item;
            }
        }
        return null;
    }

    // Enter the selected entry: its section, or the Settings window.
    function activate(index, reason) {
        current = index;
        if (index === footerIndex) panel.openSettings();
        else if (index >= 0 && index < shown.length) panel.enterPane(shown[index].id, reason);
    }

    ListCursor {
        id: plate
        parent: layout.scrollArea.contentItem
    }

    KeyNav {
        id: nav
        count: page.footerIndex + 1
        currentIndex: page.current
        viewHeight: layout.scrollArea.height
        rowHeight: Theme.listItem.height
        labelAt: index => page.labelAt(index)
        cursor: plate
        flickable: layout.scrollArea
        itemAt: index => page.itemAt(index)
        onMoved: index => page.current = index
        onActivated: index => page.activate(index, Qt.TabFocusReason)
    }

    Pane {
        id: layout
        anchors.fill: parent
        container: "window"
        bodySpacing: 0

        header: [
            TextField {
                id: search
                width: layout.contentWidth
                placeholderText: "Search sections"
                leadingIcon: "search"
                onTextChanged: page.query = text
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        if (search.text !== "") search.clear();
                        else page.focusRows(Qt.ShortcutFocusReason);
                        event.accepted = true;
                        return;
                    }
                    // Letters are the query's, not type-ahead's.
                    if (KeyNavLogic.printable(event.text, event.modifiers) !== "") return;
                    nav.textEntry = true;
                    event.accepted = nav.handle(event);
                }
            }
        ]

        // focus-indicator: the ListCursor plate marks the selected row.
        Item {
            id: list
            width: layout.contentWidth
            implicitHeight: body.implicitHeight
            activeFocusOnTab: true
            focus: true
            Accessible.name: "System sections"
            Keys.onPressed: event => {
                // Right enters a section; it never opens Settings, since
                // an arrow runs no action.
                if (event.key === Qt.Key_Right && event.modifiers === Qt.NoModifier) {
                    if (page.current < page.footerIndex) page.activate(page.current, Qt.TabFocusReason);
                    event.accepted = true;
                    return;
                }
                nav.textEntry = false;
                event.accepted = nav.handle(event);
            }

            Column {
                id: body
                width: parent.width

                EmptyState {
                    width: parent.width
                    visible: page.shown.length === 0 && page.query.trim() !== ""
                    iconName: "search-x"
                    text: "No section matches " + JSON.stringify(page.query.trim())
                    actionText: "Clear search"
                    onActivated: {
                        search.clear();
                        page.focusSearch();
                    }
                }

                Repeater {
                    id: sections
                    model: ScriptModel {
                        values: page.groups
                        objectProp: "name"
                    }

                    Section {
                        id: section
                        required property var modelData
                        readonly property int rowCount: rows.count
                        function rowAt(index) { return rows.itemAt(index); }
                        width: body.width
                        title: modelData.name
                        rowSpacing: 0
                        headerInset: rows.count > 0 && rows.itemAt(0) !== null ? rows.itemAt(0).leftPadding : 0

                        Repeater {
                            id: rows
                            model: ScriptModel {
                                values: page.shown.filter(p => p.group === section.modelData.name)
                                objectProp: "id"
                            }

                            ListItem {
                                required property var modelData
                                readonly property int entryIndex: page.shown.findIndex(p => p.id === modelData.id)
                                width: section.width
                                text: modelData.name
                                iconName: modelData.icon
                                highlighted: entryIndex === page.current
                                cursor: plate
                                onPointed: page.current = entryIndex
                                onClicked: page.activate(entryIndex, Qt.MouseFocusReason)
                            }
                        }
                    }
                }

                // The foot keeps a section's distance from the last group.
                Item {
                    width: parent.width
                    height: Theme.stack.section
                    visible: page.shown.length > 0
                }

                ListItem {
                    id: footer
                    width: parent.width
                    text: "Shell & Plugins"
                    iconName: "blocks"
                    highlighted: page.current === page.footerIndex
                    cursor: plate
                    onPointed: page.current = page.footerIndex
                    onClicked: page.activate(page.footerIndex, Qt.MouseFocusReason)
                    trailing: [
                        Icon {
                            name: "arrow-up-right"
                            size: Theme.icon.size.sm
                            color: Theme.color.textMuted
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    ]
                }
            }
        }
    }
}
