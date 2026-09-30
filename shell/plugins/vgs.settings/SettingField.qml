import QtQuick
import QtQuick.Templates as T
import qs.Commons
import qs.Ui

// One settings field from a schema entry, beside the entry's label in a
// Field: a switch for a boolean, a select for an enum or a string with
// optionsFrom, a slider with its
// value beside it for a number with both `min` and `max`, and a text field
// for any other number or a string. `apply` carries the new value; the
// field then shows what the configuration holds again, so a refused write
// leaves the old value in place. An empty or non-numeric number field
// sends NaN, which the schema refuses. The slider sends its value when a
// drag ends or a key moves it. Only Select.activated writes a choice.
// A model refresh changes the display without writing the configuration.
Field {
    id: root

    property string pluginId: ""
    property string key: ""
    property var spec: ({})
    property var value
    property var choices: []
    property bool editable: true
    readonly property bool bounded: spec.type === "number" && spec.min !== undefined && spec.max !== undefined
    signal apply(var value)

    label: spec.label !== undefined ? String(spec.label) : key
    hint: spec.description !== undefined ? String(spec.description) : ""
    inline: true

    Loader {
        id: loader
        width: parent.width
        sourceComponent: root.spec.type === "boolean" ? toggle : root.spec.type === "enum" || root.spec.optionsFrom !== undefined ? choice : root.bounded ? slider : text
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
            size: "sm"
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
            readonly property bool dynamic: root.spec.optionsFrom !== undefined
            readonly property int configuredIndex: dynamic ? root.choices.findIndex(option => option.value === root.value) : root.spec.options.indexOf(root.value)
            model: dynamic ? root.choices : root.spec.options
            textRole: dynamic ? "label" : ""
            currentIndex: configuredIndex
            enabled: root.editable
            onActivated: index => {
                const chosen = dynamic ? root.choices[index].value : root.spec.options[index];
                currentIndex = Qt.binding(() => configuredIndex);
                if (chosen === root.value) return;
                root.apply(chosen);
            }
        }
    }

    Component {
        id: slider
        Item {
            width: parent.width
            implicitHeight: Math.max(bar.implicitHeight, shown.implicitHeight)

            Slider {
                id: bar
                width: parent.width - shown.width - Theme.field.labelGap
                anchors.verticalCenter: parent.verticalCenter
                from: root.spec.min
                to: root.spec.max
                stepSize: root.spec.step === undefined ? 0 : root.spec.step
                snapMode: root.spec.step === undefined ? T.Slider.NoSnap : T.Slider.SnapAlways
                value: root.value
                enabled: root.editable
                // Commit once the drag ends, or at once for a key.
                function commit() {
                    const wanted = value;
                    value = Qt.binding(() => root.value);
                    if (wanted !== root.value) root.apply(wanted);
                }
                onPressedChanged: if (!pressed) commit()
                onMoved: if (!pressed) commit()
            }
            Label {
                id: shown
                role: "label"
                text: String(bar.value)
                width: Math.max(implicitWidth, Theme.size.control.lg)
                horizontalAlignment: Text.AlignRight
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
