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

    spacing: Style.spacing.lg

    Text {
        Layout.preferredWidth: Style.space(30)
        text: root.spec.label
        color: Color.foreground
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.small
    }

    Loader {
        Layout.fillWidth: true
        sourceComponent: root.spec.type === "boolean" ? toggle : root.spec.type === "enum" ? cycle : text
    }

    Component {
        id: text
        Rectangle {
            implicitHeight: input.implicitHeight + Style.spacing.md
            color: "transparent"
            border.color: Color.muted
            border.width: 1
            radius: Style.cornerRadius
            TextInput {
                id: input
                anchors.fill: parent
                anchors.margins: Style.spacing.xs
                text: String(root.value)
                readOnly: !root.editable
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.small
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
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.small
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
