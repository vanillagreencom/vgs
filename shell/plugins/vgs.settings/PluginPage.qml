import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// One plugin's page, drawn from its manager row alone. The header holds a
// back button, which returns to the list, and the plugin's name as a title
// whose menu lists every plugin, the current one checked, and opens the
// chosen one's page. The body holds the description, the capabilities,
// every error, the enabled switch, the listing metadata, the update and
// remove commands of an installed plugin, one settings section per schema
// group (entries without a group first, under `Settings`) and the Keys
// section. A disabled plugin's fields are read-only and say to enable it.
// The body leaves the scroll bar's gutter free whether it overflows or not,
// so every page's fields end on one right edge, and each inline value draws
// at line height 1, centred on its label.
FocusScope {
    id: page

    // The Settings panel: its rows, its replies and its navigation.
    required property Item panel
    // The manager row this page draws, or null.
    property var row: null

    readonly property bool editable: row !== null && row.enabled
    readonly property bool isSelf: row !== null && panel.shell !== null && row.id === panel.shell.manifest.id
    readonly property alias scrollArea: scroll
    readonly property alias titleMenu: menu
    readonly property alias title: title

    // The schema's keys by section: [{ group, keys }], entries without a
    // group first under "", then each group in the order its first entry
    // appears. The manifest's key order is the schema's.
    readonly property var sections: {
        if (row === null) return [];
        const out = [{ group: "", keys: [] }];
        for (const key of Object.keys(row.schema)) {
            const group = row.schema[key].group === undefined ? "" : row.schema[key].group;
            let section = out.find(s => s.group === group);
            if (section === undefined) {
                section = { group: group, keys: [] };
                out.push(section);
            }
            section.keys.push(key);
        }
        return out.filter(s => s.keys.length > 0);
    }

    function focusBack() { back.forceActiveFocus(); }

    Item {
        id: header
        x: Theme.surface.padding
        y: Theme.surface.padding
        width: parent.width - 2 * Theme.surface.padding
        height: Math.max(back.height, title.height)

        IconButton {
            id: back
            iconName: "chevron-left"
            label: "Back to the plugin list"
            anchors.verticalCenter: parent.verticalCenter
            onClicked: page.panel.back()
        }

        TitleButton {
            id: title
            x: back.width + Theme.space.sm
            width: Math.min(implicitWidth, parent.width - x)
            anchors.verticalCenter: parent.verticalCenter
            role: "h2"
            text: page.row === null ? "" : page.row.name
            menu: menu

            Menu {
                id: menu
                Repeater {
                    model: ScriptModel {
                        values: page.panel.plugins
                        objectProp: "id"
                    }
                    MenuItem {
                        required property var modelData
                        text: modelData.name
                        iconName: modelData.icon
                        checked: page.row !== null && modelData.id === page.row.id
                        onTriggered: page.panel.openPlugin(modelData.id)
                    }
                }
            }
        }
    }

    ScrollArea {
        id: scroll
        x: Theme.surface.padding
        y: header.y + header.height + Theme.space.md
        width: parent.width - 2 * Theme.surface.padding
        height: parent.height - y - Theme.surface.padding

        Column {
            id: body
            width: scroll.width - Theme.scrollArea.gutter
            spacing: Theme.space.md
            visible: page.row !== null

            Label {
                role: "body"
                text: page.row === null ? "" : page.row.description
                x: Theme.row.paddingX
                width: parent.width - 2 * Theme.row.paddingX
                wrapMode: Text.Wrap
            }

            Flow {
                x: Theme.row.paddingX
                width: parent.width - 2 * Theme.row.paddingX
                spacing: Theme.space.xs
                visible: page.row !== null && page.row.capabilities.length > 0
                Repeater {
                    model: page.row === null ? [] : page.row.capabilities
                    Badge { required property string modelData; text: modelData; iconName: "shield" }
                }
            }

            Repeater {
                model: page.row === null ? [] : page.row.errors
                Label {
                    required property string modelData
                    role: "hint"
                    text: modelData
                    color: Theme.color.danger
                    x: Theme.row.paddingX
                    width: body.width - 2 * Theme.row.paddingX
                    wrapMode: Text.Wrap
                }
            }

            Label {
                role: "hint"
                text: page.row === null ? "" : page.panel.replies[page.row.id] || ""
                visible: text !== ""
                color: Theme.color.danger
                x: Theme.row.paddingX
                width: parent.width - 2 * Theme.row.paddingX
                wrapMode: Text.Wrap
            }

            Field {
                width: parent.width
                label: "Enabled"
                inline: true
                hint: page.isSelf ? "Disabling Settings closes this window; `vgsh plugin enable " + page.row.id + "` brings it back." : page.row !== null && !page.row.enabled ? "Enable " + page.row.name + " to change its settings and keys." : ""
                Switch {
                    checked: page.row !== null && page.row.enabled
                    onToggled: {
                        checked = Qt.binding(() => page.row !== null && page.row.enabled);
                        if (page.row !== null) page.panel.toggle(page.row.id);
                    }
                }
            }

            Repeater {
                model: page.row === null ? [] : [["Author", page.row.author], ["Version", page.row.version], ["License", page.row.license], ["Source", page.row.source === "bundled" ? "Bundled with the shell" : "Installed"]].filter(pair => pair[1] !== "")
                Field {
                    id: detail
                    required property var modelData
                    width: body.width
                    label: modelData[0]
                    inline: true
                    Label { role: "item"; text: detail.modelData[1]; width: parent.width; elide: Text.ElideRight }
                }
            }

            Repeater {
                model: page.row === null || page.row.source !== "installed" ? [] : [["Update", "vgsh plugin update " + page.row.id], ["Remove", "vgsh plugin remove " + page.row.id]]
                Field {
                    id: command
                    required property var modelData
                    width: body.width
                    label: modelData[0]
                    inline: true
                    Label { role: "itemCode"; text: command.modelData[1]; width: parent.width; elide: Text.ElideRight }
                }
            }

            // Keyed models keep each section, field and key row while the
            // manager's rows are replaced, so an edit in progress survives
            // an unrelated change.
            Repeater {
                model: ScriptModel {
                    values: page.sections
                    objectProp: "group"
                }
                Column {
                    id: section
                    required property var modelData
                    width: body.width
                    spacing: Theme.space.xs

                    SectionHeader {
                        text: section.modelData.group === "" ? "Settings" : section.modelData.group
                        leftPadding: Theme.row.paddingX
                        rightPadding: Theme.row.paddingX
                    }

                    Repeater {
                        model: ScriptModel {
                            values: section.modelData.keys
                        }
                        SettingField {
                            required property string modelData
                            width: section.width
                            pluginId: page.row.id
                            key: modelData
                            spec: page.row.schema[modelData]
                            value: page.row.settings[modelData]
                            editable: page.editable
                            // An editor loses focus while the page is torn
                            // down and emits apply into a page that is
                            // gone; that edit was never committed.
                            onApply: v => { if (page !== null && page.row !== null) page.panel.writeSetting(pluginId, key, v); }
                        }
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.space.xs
                visible: page.row !== null && page.row.binds.length > 0

                SectionHeader {
                    text: "Keys"
                    description: "Written to shell.json; an empty key unbinds it"
                    leftPadding: Theme.row.paddingX
                    rightPadding: Theme.row.paddingX
                }

                Repeater {
                    model: ScriptModel {
                        values: page.row === null ? [] : page.row.binds
                        objectProp: "shortcut"
                    }
                    KeyField {
                        required property var modelData
                        width: body.width
                        pluginId: page.row.id
                        bind: modelData
                        editable: page.editable
                        onApplyKey: key => { if (page !== null && page.row !== null) page.panel.writeKey(pluginId, modelData.shortcut, key); }
                    }
                }
            }
        }
    }
}
