import QtQuick
import QtQuick.Layouts
import qs.Commons

// One settings field from a schema entry: text for a string or a number, a
// switch for a boolean, and a button cycling through the options of an
// enum. `apply` carries the new value; the field then shows what the
// configuration holds again, so a refused write leaves the old value in
// place. An empty or non-numeric number field sends NaN, which the schema
// refuses.
RowLayout {
    id: root

    property string pluginId: ""
    property string key: ""
    property var spec: ({})
    property var value
    property bool editable: true
    signal apply(var value)
    spacing: Theme.space.md

    Text {
        Layout.preferredWidth: Theme.field.labelWidth
        text: root.spec.label
        color: Theme.color.text
        elide: Text.ElideRight
        font.family: Theme.text.hint.family
        font.pixelSize: Theme.text.hint.size
    }

    Loader {
        id: loader
        Layout.fillWidth: true
        sourceComponent: root.spec.type === "boolean" ? toggle : root.spec.type === "enum" ? cycle : text
    }

    Component {
        id: text
        Rectangle {
            implicitHeight: input.implicitHeight + Theme.space.sm
            color: "transparent"
            border.color: Theme.color.border
            border.width: Theme.border.thin
            radius: Theme.radius.sm
            TextInput {
                id: input
                anchors.fill: parent
                anchors.margins: Theme.space.xxs
                text: String(root.value)
                readOnly: !root.editable
                color: Theme.color.text
                font.family: Theme.text.hint.family
                font.pixelSize: Theme.text.hint.size
                onEditingFinished: {
                    const typed = text;
                    text = Qt.binding(() => String(root.value));
                    root.apply(root.spec.type === "number" ? (typed.trim() === "" ? NaN : Number(typed)) : typed);
                }
            }
        }
    }

    Component {
        id: toggle
        Item {
            implicitHeight: sw.implicitHeight
            Switch {
                id: sw
                on: root.value === true
                onClicked: if (root.editable) root.apply(!on)
            }
        }
    }

    Component {
        id: cycle
        Text {
            text: String(root.value)
            color: Theme.color.accent
            font.family: Theme.text.hint.family
            font.pixelSize: Theme.text.hint.size
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (!root.editable) return;
                    const options = root.spec.options;
                    root.apply(options[(options.indexOf(root.value) + 1) % options.length]);
                }
            }
        }
    }
}
