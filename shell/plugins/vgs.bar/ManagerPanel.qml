import QtQuick
import QtQuick.Layouts
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

    // writeSetting from one text argument, for the validation rows: `arg`
    // is JSON {"id", "key", "value"}.
    function applySetting(arg) {
        const a = JSON.parse(arg);
        return writeSetting(a.id, a.key, a.value);
    }

    // plugin id -> the number of settings fields its form has drawn, read
    // from each form's Repeater, so a row tells a drawn form from the
    // schema handed to the panel.
    readonly property var drawnFields: {
        const out = {};
        for (let i = 0; i < rows.count; i++) {
            const item = rows.itemAt(i);
            if (item !== null) out[item.modelData.id] = item.fieldCount;
        }
        return out;
    }

    // The drawn field for setting `key` of plugin `id`, or null.
    function fieldOf(id, key) {
        for (let i = 0; i < rows.count; i++) {
            const item = rows.itemAt(i);
            if (item !== null && item.modelData.id === id) return item.field(key);
        }
        return null;
    }

    // Emit one drawn field's `apply`, as an edit in the form does, for the
    // validation rows: `arg` is JSON {"id", "key", "value"}. Answers
    // `applied` or `absent` when the form drew no such field; the write's
    // own reply is kept as a refusal on the plugin's row.
    function applyField(arg) {
        const a = JSON.parse(arg);
        const field = fieldOf(a.id, a.key);
        if (field === null) return "absent";
        field.apply(a.value);
        return "applied";
    }

    implicitWidth: Style.space(90)
    implicitHeight: Math.min(list.implicitHeight + 2 * Style.spacing.xl, Style.space(150))

    Rectangle {
        anchors.fill: parent
        color: Color.background
        radius: Style.cornerRadius
        border.color: Color.muted
        border.width: 1
    }

    Flickable {
        anchors.fill: parent
        anchors.margins: Style.spacing.xl
        contentHeight: list.implicitHeight
        clip: true

        ColumnLayout {
            id: list
            width: parent.width
            spacing: Style.spacing.lg

            Repeater {
                id: rows
                model: root.plugins

                ColumnLayout {
                    id: entry
                    required property var modelData
                    readonly property int fieldCount: fields.count
                    function field(key) {
                        for (let i = 0; i < fields.count; i++) {
                            const item = fields.itemAt(i);
                            if (item !== null && item.key === key) return item;
                        }
                        return null;
                    }
                    Layout.fillWidth: true
                    spacing: Style.spacing.sm

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            Layout.fillWidth: true
                            text: entry.modelData.name
                            color: Color.foreground
                            font.family: Style.font.family
                            font.pixelSize: Style.font.size
                            elide: Text.ElideRight
                        }
                        Text {
                            text: entry.modelData.version
                            color: Color.muted
                            font.family: Style.font.family
                            font.pixelSize: Style.font.small
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
                        color: Color.urgent
                        wrapMode: Text.Wrap
                        font.family: Style.font.family
                        font.pixelSize: Style.font.small
                    }

                    Text {
                        Layout.fillWidth: true
                        text: entry.modelData.description
                        color: Color.muted
                        wrapMode: Text.Wrap
                        font.family: Style.font.family
                        font.pixelSize: Style.font.small
                    }

                    Repeater {
                        id: fields
                        model: Object.keys(entry.modelData.schema)

                        SettingField {
                            required property string modelData
                            Layout.fillWidth: true
                            pluginId: entry.modelData.id
                            key: modelData
                            spec: entry.modelData.schema[modelData]
                            value: entry.modelData.settings[modelData]
                            editable: entry.modelData.enabled
                            onApply: v => root.writeSetting(pluginId, key, v)
                        }
                    }
                }
            }
        }
    }
}
