import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// One plugin's page, drawn from its manager row alone. The header holds a
// back button, which returns to the list, and the plugin's name as a title
// whose menu lists every plugin, the current one checked, and opens the
// chosen one's page. The body holds the description, the capabilities,
// every error, the enabled switch, the listing metadata, the Update and
// Remove buttons of an installed plugin, one status section per status
// group (entries without a group first, under `Status`), whose values are
// read-only and whose setup steps run through the manager (D058), the
// Requirements section with an Install button while one is missing, one
// settings section per schema group (entries without a group first, under
// `Settings`) and the Keys section. A disabled plugin's fields are
// read-only and say to enable it; its status rows say it has not reported.
// The header and body share one content edge, the scroll bar sits in the
// window's right inset, and each inline value draws at line height 1,
// centred on its label. The description draws in the hint role in the
// muted colour; the enabled switch, the listing metadata and Manage are
// one key/value group `stack.row` apart, the read-only metadata in compact
// rows.
FocusScope {
    id: page

    // The Settings panel: its rows, its replies and its navigation.
    required property Item panel
    // The manager row this page draws, or null.
    property var row: null

    readonly property bool editable: row !== null && row.enabled
    // Whether a requirement of the plugin was missing at the last scan.
    readonly property bool requirementMissing: row !== null && row.requirements.some(r => r.state === "missing")
    readonly property bool isSelf: row !== null && panel.shell !== null && row.id === panel.shell.manifest.id
    readonly property alias scrollArea: layout.scrollArea
    readonly property alias titleMenu: menu
    readonly property alias title: titleHeader.titleButton

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

    // The displayable status entries' keys by section, as `sections` holds
    // the schema's: [{ group, keys }], ungrouped first, then each group in
    // the order its first entry appears. The row's `status` is in manifest
    // order and holds no `data`, `choices` or hidden entry.
    readonly property var statusSections: {
        if (row === null) return [];
        const out = [{ group: "", keys: [] }];
        for (const entry of row.status) {
            let section = out.find(s => s.group === entry.group);
            if (section === undefined) {
                section = { group: entry.group, keys: [] };
                out.push(section);
            }
            section.keys.push(entry.key);
        }
        return out.filter(s => s.keys.length > 0);
    }

    function statusEntry(key) {
        return row === null ? null : row.status.find(entry => entry.key === key) || null;
    }

    function focusBack() { back.forceActiveFocus(); }

    Pane {
        id: layout
        anchors.fill: parent
        container: "window"
        bodySpacing: 0

        header: [
            PageHeader {
                id: titleHeader
                width: parent.width
                text: page.row === null ? "" : page.row.name
                menu: menu

                leading: [
                    IconButton {
                        id: back
                        iconName: "chevron-left"
                        label: "Back to the plugin list"
                        anchors.verticalCenter: parent.verticalCenter
                        onClicked: page.panel.back()
                    }
                ]

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
        ]

        Column {
            id: body
            width: parent.width
            spacing: Theme.stack.group
            visible: page.row !== null

            Label {
                role: "hint"
                color: Theme.color.textMuted
                text: page.row === null ? "" : page.row.description
                width: parent.width
                wrapMode: Text.Wrap
            }

            Flow {
                width: parent.width
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
                    width: body.width
                    wrapMode: Text.Wrap
                }
            }

            Label {
                role: "hint"
                text: page.row === null ? "" : page.panel.replies[page.row.id] || ""
                visible: text !== ""
                color: Theme.color.danger
                width: parent.width
                wrapMode: Text.Wrap
            }

            Column {
                width: parent.width
                spacing: Theme.stack.row

                Field {
                    id: enabledField
                    width: parent.width
                    label: "Enabled"
                    inline: true
                    hint: page.isSelf ? "Disabling Settings closes this window and takes its gear from the bar." : page.row !== null && !page.row.enabled ? "Enable " + page.row.name + " to change its settings and keys." : ""
                    Switch {
                        size: "sm"
                        checked: page.row !== null && page.row.enabled
                        onToggled: {
                            checked = Qt.binding(() => page.row !== null && page.row.enabled);
                            if (page.row !== null) page.panel.toggle(page.row.id);
                        }
                    }
                }

                // Once Settings is off no window is left to hold a button that
                // turns it on, so its own page keeps the command that does,
                // behind Show command (D058).
                CommandDisclosure {
                    x: enabledField.valueX
                    width: parent.width - x - enabledField.rightPadding
                    visible: page.isSelf
                    command: page.row === null ? "" : "vgsh plugin enable " + page.row.id
                }

                Repeater {
                    model: page.row === null ? [] : [["Author", page.row.author], ["Version", page.row.version], ["License", page.row.license], ["Source", page.row.source === "bundled" ? "Bundled with the shell" : "Installed"]].filter(pair => pair[1] !== "")
                    Field {
                        id: detail
                        required property var modelData
                        width: body.width
                        label: modelData[0]
                        inline: true
                        compact: true
                        Label { role: "item"; text: detail.modelData[1]; width: parent.width; elide: Text.ElideRight }
                    }
                }

                // A bundled plugin is disabled, never updated or removed.
                Field {
                    width: parent.width
                    label: "Manage"
                    inline: true
                    visible: page.row !== null && page.row.source === "installed"
                    hint: "Each opens a terminal that asks before it changes anything."
                    Row {
                        spacing: Theme.stack.inline
                        Button {
                            text: "Update"
                            iconName: "refresh-cw"
                            variant: "secondary"
                            onClicked: page.panel.updatePlugin(page.row.id)
                        }
                        Button {
                            text: "Remove"
                            iconName: "trash"
                            variant: "danger"
                            onClicked: page.panel.removePlugin(page.row.id)
                        }
                    }
                }
            }

            // What the plugin published, read-only, above what can be set.
            Repeater {
                model: ScriptModel {
                    values: page.statusSections
                    objectProp: "group"
                }
                Section {
                    id: statusSection
                    required property var modelData
                    width: body.width
                    title: statusSection.modelData.group === "" ? "Status" : statusSection.modelData.group

                    Repeater {
                        model: ScriptModel {
                            values: statusSection.modelData.keys
                        }
                        StatusRow {
                            required property string modelData
                            width: statusSection.width
                            entry: page.statusEntry(modelData)
                            panel: page.panel
                            pluginId: page.row === null ? "" : page.row.id
                            secretLabel: page.row === null ? "" : page.row.secretLabel
                        }
                    }
                }
            }

            Section {
                width: parent.width
                visible: page.row !== null && page.row.requirements.length > 0
                title: "Requirements"
                description: "Commands the plugin runs, looked up on PATH at the last scan"

                Column {
                    id: requirementRows
                    width: parent.width
                    spacing: Theme.stack.row

                    Repeater {
                        model: ScriptModel {
                            values: page.row === null ? [] : page.row.requirements
                            objectProp: "command"
                        }
                        RequirementRow {
                            required property var modelData
                            width: requirementRows.width
                            requirement: modelData
                        }
                    }
                }

                Field {
                    width: parent.width
                    label: "Missing"
                    inline: true
                    visible: page.requirementMissing
                    hint: "Opens a terminal that names each package and asks before it installs them."
                    Button {
                        text: "Install"
                        iconName: "download"
                        variant: "primary"
                        onClicked: page.panel.installRequirements(page.row.id)
                    }
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
                Section {
                    id: section
                    required property var modelData
                    width: body.width
                    title: section.modelData.group === "" ? "Settings" : section.modelData.group

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
                            choices: page.row.settingChoices[modelData] || []
                            editable: page.editable
                            // An editor loses focus while the page is torn
                            // down and emits apply into a page that is
                            // gone; that edit was never committed.
                            onApply: v => { if (page !== null && page.row !== null) page.panel.writeSetting(pluginId, key, v); }
                        }
                    }
                }
            }

            Section {
                width: parent.width
                visible: page.row !== null && page.row.binds.length > 0
                title: "Keys"
                description: "Written to shell.json; an empty key unbinds it"

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
