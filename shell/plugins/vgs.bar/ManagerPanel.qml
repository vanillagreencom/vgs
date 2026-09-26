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

    // The text editor inside one drawn field, or null for a field that
    // draws none (a switch, an enum).
    function editorOf(field) {
        if (field === null) return null;
        for (let i = 0; i < field.children.length; i++) {
            const child = field.children[i];
            if (child.item !== undefined && child.item !== null && child.item.children.length > 0
                    && child.item.children[0].cursorPosition !== undefined)
                return child.item.children[0];
        }
        return null;
    }

    // The field an edit is under way in, for the validation rows: `arg` is
    // JSON {"id", "key", "text"}. Focuses the field's editor and types
    // `text` into it, as a user who has not left the field yet. Answers
    // `held`, or `absent` when no such editor is drawn.
    property var heldField: null
    function holdField(arg) {
        const a = JSON.parse(arg);
        const editor = editorOf(fieldOf(a.id, a.key));
        if (editor === null) return "absent";
        editor.forceActiveFocus();
        editor.text = a.text;
        editor.cursorPosition = 1;
        heldField = { id: a.id, key: a.key, field: fieldOf(a.id, a.key), editor: editor };
        return "held";
    }

    // What became of the held field: JSON { same, focus, activeFocus,
    // text, cursor } where `same` says the drawn field is still the object
    // held, and the rest is read from that editor; `activeFocus` is true
    // only while the compositor gives this window keyboard focus. `absent`
    // with nothing held.
    function heldFieldState() {
        if (heldField === null) return "absent";
        return JSON.stringify({
            same: fieldOf(heldField.id, heldField.key) === heldField.field,
            focus: heldField.editor.focus,
            activeFocus: heldField.editor.activeFocus,
            text: heldField.editor.text,
            cursor: heldField.editor.cursorPosition
        });
    }

    // The held editor's rectangle as JSON [x, y, width, height] in the
    // coordinates of the window this panel was anchored in, for a row that
    // clicks it. `absent` with nothing held.
    function heldFieldGeometry() {
        if (heldField === null) return "absent";
        const at = heldField.editor.mapToGlobal(0, 0);
        return JSON.stringify([at.x, at.y, heldField.editor.width, heldField.editor.height]);
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
                model: ScriptModel {
                    values: root.plugins
                    objectProp: "id"
                }

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
