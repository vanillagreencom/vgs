import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The root page: every plugin the manager lists, filtered by the search
// field, under a heading with the Add plugin button. A row shows the plugin's icon, name, version and source, a danger
// badge counting its errors, its enabled switch and a chevron; a click
// opens its page. With the search field focused, Up and Down move the
// highlighted row and Enter opens it; a hover moves it once the pointer
// moves, and one ListCursor draws it and travels between rows. The heading,
// the search field and the rows share the list's content edges. Each row
// then owns its own icon inset, and the scroll bar sits in the window's
// right inset.
FocusScope {
    id: page

    // The Settings panel: its rows, its notice and its navigation.
    required property Item panel
    property string query: ""
    // The index in `shown` the keyboard has highlighted.
    property int current: 0

    // The rows whose name, id or description holds the query.
    readonly property var shown: {
        const wanted = query.trim().toLowerCase();
        return panel.plugins.filter(p => wanted === "" || [p.name, p.id, p.description].some(t => String(t).toLowerCase().indexOf(wanted) !== -1));
    }
    readonly property alias scrollArea: layout.scrollArea
    readonly property alias initialFocus: search

    Keys.onPressed: event => { event.accepted = handleKey(event); }

    // The rows change under a resting pointer: it takes no row until it
    // moves, and the cursor lands on the row the keyboard keeps.
    onShownChanged: {
        plate.disarm();
        plate.snap();
        current = Math.max(0, Math.min(current, shown.length - 1));
    }

    function focusSearch(reason) { search.forceActiveFocus(reason === undefined ? Qt.TabFocusReason : reason); }

    function handleKey(event) {
        const accepted = nav.handle(event);
        if (accepted) return true;
        const typed = KeyNavLogic.printable(event.text, event.modifiers);
        if (typed === "" || search.activeFocus) return false;
        focusSearch(Qt.ShortcutFocusReason);
        search.insert(search.cursorPosition, typed);
        return true;
    }

    function openCurrent(reason) {
        if (current >= 0 && current < shown.length) panel.openPlugin(shown[current].id, reason);
    }

    // The rows' cursor, in the body's scrolling content with the rows.
    ListCursor {
        id: plate
        parent: layout.scrollArea.contentItem
    }

    KeyNav {
        id: nav
        count: page.shown.length
        currentIndex: page.current
        textEntry: true
        viewHeight: layout.scrollArea.height
        rowHeight: Theme.listItem.twoLineHeight
        cursor: plate
        flickable: layout.scrollArea
        itemAt: index => rows.itemAt(index)
        onMoved: index => page.current = index
        onActivated: index => page.openCurrent(Qt.TabFocusReason)
    }

    Pane {
        id: layout
        anchors.fill: parent
        container: "window"
        bodySpacing: 0

        header: [
            Column {
                width: layout.contentWidth
                spacing: Theme.stack.group

                PageHeader {
                    width: layout.contentWidth
                    text: page.panel.title

                    trailing: [
                        Button {
                            id: add
                            text: "Add plugin"
                            iconName: "circle-plus"
                            variant: "secondary"
                            anchors.verticalCenter: parent.verticalCenter
                            onClicked: page.panel.addPlugin()
                        }
                    ]
                }
                Label {
                    role: "hint"
                    text: page.panel.notice
                    visible: text !== ""
                    color: Theme.color.warning
                    width: parent.width
                    wrapMode: Text.Wrap
                }
                TextField {
                    id: search
                    width: parent.width
                    placeholderText: "Search plugins"
                    leadingIcon: "search"
                    focus: true
                    onTextChanged: page.query = text
                    Keys.onPressed: event => { event.accepted = nav.handle(event); }
                }
            }
        ]

        // The empty result: an icon, one line and a way back.
        EmptyState {
            id: empty
            visible: page.shown.length === 0
            width: layout.contentWidth
            iconName: "search-x"
            text: "No plugin matches " + JSON.stringify(page.query.trim())
            actionText: "Clear search"
            onActivated: {
                search.clear();
                search.forceActiveFocus();
            }
        }

        Repeater {
            id: rows
            model: ScriptModel {
                values: page.shown
                objectProp: "id"
            }

            ListItem {
                id: entry
                required property var modelData
                required property int index
                width: layout.contentWidth
                text: modelData.name
                secondary: modelData.version + "  " + (modelData.source === "bundled" ? "Bundled" : "Installed")
                iconName: modelData.icon
                highlighted: index === page.current
                cursor: plate
                onPointed: page.current = index
                onClicked: page.panel.openPlugin(modelData.id, Qt.MouseFocusReason)
                trailing: [
                    Badge {
                        tone: "danger"
                        iconName: "circle-alert"
                        text: String(entry.modelData.errors.length)
                        visible: entry.modelData.errors.length > 0
                        anchors.verticalCenter: parent.verticalCenter
                    },
                    // keyboard-path: open the row and use the plugin page's Enabled switch
                    Switch {
                        size: "sm"
                        checked: entry.modelData.enabled
                        focusPolicy: Qt.NoFocus
                        anchors.verticalCenter: parent.verticalCenter
                        onToggled: {
                            checked = Qt.binding(() => entry.modelData.enabled);
                            page.panel.toggle(entry.modelData.id);
                        }
                    },
                    Icon {
                        name: "chevron-right"
                        size: Theme.icon.size.sm
                        color: Theme.color.textMuted
                        anchors.verticalCenter: parent.verticalCenter
                    }
                ]
            }
        }
    }
}
