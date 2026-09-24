import QtQuick
import QtQuick.Layouts
import qs.Commons

// The plugin manager: every discovered plugin with its enabled state, and a
// settings form for each plugin whose manifest declares a schema. Toggling
// and writing go through the manager capability, which calls the core
// functions `setPluginEnabled` and the settings writer use; the rows come
// back from the core, so the panel shows what the configuration holds.
Item {
    id: root

    property var shell: null
    readonly property var plugins: shell === null ? [] : shell.manager.plugins
    // "<plugin id>:<setting>" for every settings field drawn now.
    property var renderedFields: []

    function open(payloadJson) {}
    function close() {}

    // Enable or disable plugin `id`, the opposite of its state now; answers
    // the manager's reply.
    function toggle(id) {
        const row = plugins.filter(p => p.id === id)[0];
        if (row === undefined) return "unknown: " + id;
        return shell.manager.setEnabled(id, !row.enabled);
    }

    // Write one setting as a form field does. `arg` is JSON
    // {"id", "key", "value"}; answers the manager's reply.
    function applySetting(arg) {
        const a = JSON.parse(arg);
        return shell.manager.setSetting(a.id, a.key, a.value);
    }

    function fieldShown(name, shown) {
        const at = renderedFields.indexOf(name);
        if (shown && at === -1) renderedFields = renderedFields.concat([name]);
        else if (!shown && at !== -1) renderedFields = renderedFields.filter(f => f !== name);
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
                model: root.plugins

                ColumnLayout {
                    id: entry
                    required property var modelData
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
                        text: entry.modelData.description
                        color: Color.muted
                        wrapMode: Text.Wrap
                        font.family: Style.font.family
                        font.pixelSize: Style.font.small
                    }

                    Repeater {
                        model: Object.keys(entry.modelData.schema)

                        SettingField {
                            required property string modelData
                            Layout.fillWidth: true
                            pluginId: entry.modelData.id
                            key: modelData
                            spec: entry.modelData.schema[modelData]
                            value: entry.modelData.settings[modelData]
                            editable: entry.modelData.enabled
                            onApply: v => root.shell.manager.setSetting(pluginId, key, v)
                            Component.onCompleted: root.fieldShown(pluginId + ":" + key, true)
                            Component.onDestruction: root.fieldShown(pluginId + ":" + key, false)
                        }
                    }
                }
            }
        }
    }
}
