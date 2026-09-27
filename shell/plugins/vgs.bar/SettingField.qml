import QtQuick
import qs.Commons
import qs.Ui

// One settings field from a schema entry: a text field for a string or a
// number, a switch for a boolean, and a select for an enum, each under the
// entry's label in a Field. `apply` carries the new value; the field then
// shows what the configuration holds again, so a refused write leaves the
// old value in place. An empty or non-numeric number field sends NaN,
// which the schema refuses. The select assigns its index only on a
// different choice, so choosing the current option keeps the binding.
Field {
    id: root

    property string pluginId: ""
    property string key: ""
    property var spec: ({})
    property var value
    property bool editable: true
    signal apply(var value)

    label: spec.label !== undefined ? String(spec.label) : key
    hint: spec.description !== undefined ? String(spec.description) : ""
    inline: true

    Loader {
        id: loader
        width: parent.width
        sourceComponent: root.spec.type === "boolean" ? toggle : root.spec.type === "enum" ? choice : text
    }

    Component {
        id: text
        TextField {
            id: input
            width: parent.width
            text: String(root.value)
            readOnly: !root.editable
            onEditingFinished: {
                const typed = text;
                text = Qt.binding(() => String(root.value));
                root.apply(root.spec.type === "number" ? (typed.trim() === "" ? NaN : Number(typed)) : typed);
            }
        }
    }

    Component {
        id: toggle
        Switch {
            checked: root.value === true
            enabled: root.editable
            onToggled: {
                const wanted = checked;
                checked = Qt.binding(() => root.value === true);
                root.apply(wanted);
            }
        }
    }

    Component {
        id: choice
        Select {
            width: parent.width
            model: root.spec.options
            currentIndex: Math.max(0, root.spec.options.indexOf(root.value))
            enabled: root.editable
            onCurrentIndexChanged: {
                const chosen = root.spec.options[currentIndex];
                if (chosen === root.value) return;
                currentIndex = Qt.binding(() => Math.max(0, root.spec.options.indexOf(root.value)));
                root.apply(chosen);
            }
        }
    }
}
