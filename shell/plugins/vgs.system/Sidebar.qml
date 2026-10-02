import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The System window's sidebar: a search field, then every enabled section
// under the heading of its group, in the order the panes capability lists
// them, then the Shell & Plugins row at the foot. The search field holds
// the keys, as the Settings list's does (keyboard.md K6): typed text
// filters the rows, and printable text typed elsewhere in the sidebar goes
// to it. One ListCursor marks the selected row: Up, Down, the pages and
// Ctrl+Home or Ctrl+End move it, and a hover moves it once the pointer
// moves. Enter, or Right with the caret at the end of the query, enters
// the selected section, and Enter on Shell & Plugins opens the Settings
// window, as a click does. Escape with a query clears it; with none it is
// left to the window, which closes. The selection follows its entry by
// id, so a section joining or leaving the list moves no other row's
// selection.
FocusScope {
    id: page

    // The System window: its sections, the shown section and the steps.
    required property Item panel
    property string query: ""
    // The selected entry: a section id, or `footerKey` for Shell & Plugins.
    property string currentKey: ""
    // Its index: a section of `shown`, or `footerIndex` for Shell &
    // Plugins.
    property int current: 0
    // No plugin id has a `#`, so this key names no section.
    readonly property string footerKey: "#shell-and-plugins"

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

    Keys.onPressed: event => { event.accepted = handleKey(event); }

    // The rows change under a resting pointer: it takes no row until it
    // moves, and the cursor lands on the row the keyboard keeps. The
    // selected entry keeps the selection wherever it now sits; one that
    // left the list hands it to the entry at its place.
    onShownChanged: {
        plate.disarm();
        plate.snap();
        const at = indexOf(currentKey);
        selectIndex(at !== -1 ? at : Math.max(0, Math.min(current, shown.length)));
    }

    // A new query selects its first match.
    onQueryChanged: selectIndex(0)

    function focusSearch(reason) { search.forceActiveFocus(reason === undefined ? Qt.TabFocusReason : reason); }

    // These read `shown` itself, not `footerIndex`: onShownChanged can run
    // while that binding still holds the old list's length
    // (runtime-qml.md).
    function keyAt(index) { return index === shown.length ? footerKey : index >= 0 && index < shown.length ? shown[index].id : ""; }
    function indexOf(key) { return key === footerKey ? shown.length : shown.findIndex(p => p.id === key); }

    function selectIndex(index) {
        current = index;
        currentKey = keyAt(index);
    }

    // Select the section `id` when the list shows it.
    function select(id) {
        const index = indexOf(id);
        if (index !== -1) selectIndex(index);
    }

    // The key the sidebar holds: the cursor's movement, else printable
    // text, which goes to the search field.
    function handleKey(event) {
        if (nav.handle(event)) return true;
        const typed = KeyNavLogic.printable(event.text, event.modifiers);
        if (typed === "" || search.activeFocus) return false;
        focusSearch(Qt.ShortcutFocusReason);
        search.insert(search.cursorPosition, typed);
        return true;
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
        selectIndex(index);
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
        textEntry: true
        viewHeight: layout.scrollArea.height
        rowHeight: Theme.listItem.height
        cursor: plate
        flickable: layout.scrollArea
        itemAt: index => page.itemAt(index)
        onMoved: index => page.selectIndex(index)
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
                focus: true
                onTextChanged: page.query = text
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape && search.text !== "") {
                        search.clear();
                        event.accepted = true;
                        return;
                    }
                    // Right past the end of the query enters the selected
                    // section; it never opens Settings, since an arrow
                    // runs no action.
                    if (event.key === Qt.Key_Right && event.modifiers === Qt.NoModifier && search.cursorPosition === search.length) {
                        if (page.current < page.footerIndex) page.activate(page.current, Qt.TabFocusReason);
                        event.accepted = true;
                        return;
                    }
                    event.accepted = nav.handle(event);
                }
            }
        ]

        Item {
            width: layout.contentWidth
            implicitHeight: body.implicitHeight

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
                                onPointed: page.selectIndex(entryIndex)
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
                    onPointed: page.selectIndex(page.footerIndex)
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
