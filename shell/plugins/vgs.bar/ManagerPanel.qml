import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import "Reply.js" as Reply

// The plugin manager: every discovered plugin with its enabled state, and a
// settings form for each plugin whose manifest declares a schema. Toggling
// and writing go through the manager capability, which calls the core
// functions `setPluginEnabled` and the settings writer use; the rows come
// back from the core, so the panel shows what the configuration holds.
Item {
    id: root

    property var shell: null
    readonly property var plugins: shell === null ? [] : shell.manager.plugins
    // plugin id -> the last refusal the manager answered for it, shown on
    // its row until a later call for that plugin succeeds.
    property var replies: ({})

    // Keep one manager reply for plugin `id` and answer it.
    function keep(id, reply) {
        const next = Object.assign({}, replies);
        if (Reply.isOk(reply)) delete next[id];
        else {
            next[id] = reply;
            console.warn("manager panel: " + id + " " + reply);
        }
        replies = next;
        return reply;
    }

    // The panel takes no payload; what a summoner passes is ignored.
    function open(payloadJson) {}
    function close() {}

    // Enable or disable plugin `id`, the opposite of its state now; answers
    // the manager's reply.
    function toggle(id) {
        const row = plugins.filter(p => p.id === id)[0];
        if (row === undefined) return "unknown: " + id;
        return keep(id, shell.manager.setEnabled(id, !row.enabled));
    }

    // Write one setting of plugin `id` through the manager; answers its
    // reply. Every form field and the validation rows write through here.
    function writeSetting(id, key, value) {
        return keep(id, shell.manager.setSetting(id, key, value));
    }

    implicitWidth: Theme.size.panel.md
    implicitHeight: Math.min(list.implicitHeight + 2 * Theme.space.lg, Theme.size.panel.maxHeight)

    Rectangle {
        anchors.fill: parent
        color: Theme.color.surface
        radius: Theme.radius.md
        border.color: Theme.color.border
        border.width: Theme.border.thin
    }

    Flickable {
        anchors.fill: parent
        anchors.margins: Theme.space.lg
        contentHeight: list.implicitHeight
        clip: true

        ColumnLayout {
            id: list
            width: parent.width
            spacing: Theme.space.md

            Repeater {
                id: rows
                model: ScriptModel {
                    values: root.plugins
                    objectProp: "id"
                }

                ColumnLayout {
                    id: entry
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: Theme.space.xs

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            Layout.fillWidth: true
                            text: entry.modelData.name
                            color: Theme.color.text
                            font.family: Theme.text.body.family
                            font.pixelSize: Theme.text.body.size
                            elide: Text.ElideRight
                        }
                        Text {
                            text: entry.modelData.version
                            color: Theme.color.textMuted
                            font.family: Theme.text.hint.family
                            font.pixelSize: Theme.text.hint.size
                        }
                        Switch {
                            on: entry.modelData.enabled
                            onClicked: root.toggle(entry.modelData.id)
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: text !== ""
                        text: root.replies[entry.modelData.id] || ""
                        color: Theme.color.danger
                        wrapMode: Text.Wrap
                        font.family: Theme.text.hint.family
                        font.pixelSize: Theme.text.hint.size
                    }

                    Text {
                        Layout.fillWidth: true
                        text: entry.modelData.description
                        color: Theme.color.textMuted
                        wrapMode: Text.Wrap
                        font.family: Theme.text.hint.family
                        font.pixelSize: Theme.text.hint.size
                    }

                    Repeater {
                        id: fields
                        model: ScriptModel {
                            values: Object.keys(entry.modelData.schema)
                        }

                        SettingField {
                            required property string modelData
                            Layout.fillWidth: true
                            pluginId: entry.modelData.id
                            key: modelData
                            spec: entry.modelData.schema[modelData]
                            value: entry.modelData.settings[modelData]
                            editable: entry.modelData.enabled
                            // An editor loses focus while the panel is
                            // torn down and emits apply into a panel that
                            // is gone; that edit was never committed.
                            onApply: v => { if (root !== null) root.writeSetting(pluginId, key, v); }
                        }
                    }
                }
            }
        }
    }
}
