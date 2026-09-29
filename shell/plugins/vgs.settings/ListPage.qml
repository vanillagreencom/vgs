import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The root page: every plugin the manager lists, filtered by the search
// field, under a heading with the Add plugin button. A row shows the plugin's icon, name, version and source, a danger
// badge counting its errors, its enabled switch and a chevron; a click
// opens its page. With the search field focused, Up and Down move the
// highlighted row and Enter opens it. The heading, the search field and the
// rows share the list's content edges. Each row then owns its own icon
// inset, and the scroll bar sits in the window's right inset.
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

    onShownChanged: current = Math.max(0, Math.min(current, shown.length - 1))

    function focusSearch() { search.forceActiveFocus(); }

    function move(step) {
        if (shown.length === 0) return;
        current = Math.max(0, Math.min(shown.length - 1, current + step));
        const item = rows.itemAt(current);
        if (item === null) return;
        if (item.y < layout.scrollArea.contentY) layout.scrollArea.contentY = item.y;
        else if (item.y + item.height > layout.scrollArea.contentY + layout.scrollArea.height) layout.scrollArea.contentY = item.y + item.height - layout.scrollArea.height;
    }

    function openCurrent() {
        if (current >= 0 && current < shown.length) panel.openPlugin(shown[current].id);
    }

    Pane {
        id: layout
        anchors.fill: parent
        container: "window"
        bodySpacing: 0

        header: [
            Column {
                width: layout.contentWidth
                spacing: Theme.space.sm

                Item {
                    width: layout.contentWidth
                    height: Math.max(heading.height, add.height)

                    Label {
                        id: heading
                        role: "h2"
                        text: page.panel.title
                        width: add.x - Theme.space.sm
                        elide: Text.ElideRight
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Button {
                        id: add
                        text: "Add plugin"
                        iconName: "circle-plus"
                        variant: "secondary"
                        size: "sm"
                        x: parent.width - width
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: page.panel.addPlugin()
                    }
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
                    Keys.onUpPressed: page.move(-1)
                    Keys.onDownPressed: page.move(1)
                    Keys.onReturnPressed: page.openCurrent()
                    Keys.onEnterPressed: page.openCurrent()
                }
            }
        ]

        Label {
            role: "hint"
            text: "No plugin matches " + JSON.stringify(page.query.trim())
            visible: page.shown.length === 0
            width: parent.width
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
                width: layout.contentWidth
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
