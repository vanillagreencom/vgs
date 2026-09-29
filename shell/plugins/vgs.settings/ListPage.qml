import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The root page: every plugin the manager lists, filtered by the search
// field, under a heading with the Add plugin button. A row shows the plugin's icon, name, version and source, a danger
// badge counting its errors, its enabled switch and a chevron; a click
// opens its page. With the search field focused, Up and Down move the
// highlighted row and Enter opens it. The heading, the search field and the
// rows share the list's edges, which leave the scroll bar's gutter free
// whether the list overflows or not; the heading's text starts where a
// row's icon does.
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
    readonly property alias scrollArea: scroll
    // The width every row and the header span.
    readonly property real listWidth: width - 2 * Theme.surface.padding - Theme.scrollArea.gutter

    onShownChanged: current = Math.max(0, Math.min(current, shown.length - 1))

    function focusSearch() { search.forceActiveFocus(); }

    function move(step) {
        if (shown.length === 0) return;
        current = Math.max(0, Math.min(shown.length - 1, current + step));
        const item = rows.itemAt(current);
        if (item === null) return;
        if (item.y < scroll.contentY) scroll.contentY = item.y;
        else if (item.y + item.height > scroll.contentY + scroll.height) scroll.contentY = item.y + item.height - scroll.height;
    }

    function openCurrent() {
        if (current >= 0 && current < shown.length) panel.openPlugin(shown[current].id);
    }

    Column {
        id: header
        x: Theme.surface.padding
        y: Theme.surface.padding
        width: page.listWidth
        spacing: Theme.space.sm

        Item {
            width: parent.width
            height: Math.max(heading.height, add.height)

            Label {
                id: heading
                role: "h2"
                text: page.panel.title
                x: Theme.row.paddingX
                width: add.x - x - Theme.space.sm
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
            }
            Button {
                id: add
                text: "Add plugin"
                iconName: "circle-plus"
                variant: "secondary"
                size: "sm"
                x: parent.width - width - Theme.row.paddingX
                anchors.verticalCenter: parent.verticalCenter
                onClicked: page.panel.addPlugin()
            }
        }
        Label {
            role: "hint"
            text: page.panel.notice
            visible: text !== ""
            color: Theme.color.warning
            x: Theme.row.paddingX
            width: parent.width - 2 * Theme.row.paddingX
            wrapMode: Text.Wrap
        }
        TextField {
            id: search
            width: parent.width
            placeholderText: "Search plugins"
            leadingIcon: "search"
            focus: true
            onTextChanged: page.query = text
            Keys.onUpPressed: page.move(-1)
            Keys.onDownPressed: page.move(1)
            Keys.onReturnPressed: page.openCurrent()
            Keys.onEnterPressed: page.openCurrent()
        }
    }

    ScrollArea {
        id: scroll
        x: Theme.surface.padding
        y: header.y + header.height + Theme.space.sm
        width: parent.width - 2 * Theme.surface.padding
        height: parent.height - y - Theme.surface.padding

        Column {
            id: list
            width: page.listWidth

            Label {
                role: "hint"
                text: "No plugin matches " + JSON.stringify(page.query.trim())
                visible: page.shown.length === 0
                x: Theme.row.paddingX
                width: parent.width - 2 * Theme.row.paddingX
                wrapMode: Text.Wrap
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
                    // The list, not `parent`, which is null while the
                    // repeater tears the row down.
                    width: list.width
                    text: modelData.name
                    secondary: modelData.version + "  " + (modelData.source === "bundled" ? "Bundled" : "Installed")
                    iconName: modelData.icon
                    highlighted: index === page.current
                    onClicked: page.panel.openPlugin(modelData.id)
                    trailing: [
                        Badge {
                            tone: "danger"
                            iconName: "circle-alert"
                            text: String(entry.modelData.errors.length)
                            visible: entry.modelData.errors.length > 0
                            anchors.verticalCenter: parent.verticalCenter
                        },
                        Switch {
                            checked: entry.modelData.enabled
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
}
