import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The root page: every plugin the manager lists, filtered by the search
// field. A row shows the plugin's icon, name, version and source, a danger
// badge counting its errors, its enabled switch and a chevron; a click
// opens its page. With the search field focused, Up and Down move the
// highlighted row and Enter opens it.
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
        width: parent.width - 2 * Theme.surface.padding
        spacing: Theme.space.sm

        Label {
            role: "h2"
            text: page.panel.title
            x: Theme.row.paddingX
            width: parent.width - 2 * Theme.row.paddingX
            elide: Text.ElideRight
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
            width: parent.width

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
