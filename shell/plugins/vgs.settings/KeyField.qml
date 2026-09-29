import QtQuick
import qs.Commons
import qs.Ui

// One row of a plugin's Keys section, from one bind the manager lists:
// the shortcut's name beside a text field holding the key in effect,
// written `MOD+KEY`, with the description the plugin registered and the
// manifest's key under it. Editing the field sends that key, an emptied
// field sends null, which unbinds it, and the reset button sends
// undefined, which removes the shell.json entry so the manifest's key
// applies; the unbind and reset buttons show only where they change
// something. The field then shows what the configuration holds again, so
// a refused key leaves the old one in place.
Field {
    id: root

    property string pluginId: ""
    // { shortcut, key, default, description }; `key` is null while unbound.
    property var bind: ({})
    property bool editable: true
    signal applyKey(var key)

    readonly property string shown: bind.key === null || bind.key === undefined ? "" : String(bind.key)

    label: String(bind.shortcut)
    hint: (bind.description ? String(bind.description) + ". " : "") + (bind.key === bind["default"] ? "The manifest's key." : "The manifest's key is " + bind["default"] + ".")
    inline: true
    contentPaddingX: 0

    TextField {
        id: input
        width: parent.width
        text: root.shown
        placeholderText: "Unbound"
        readOnly: !root.editable
        onEditingFinished: {
            const typed = text.trim();
            text = Qt.binding(() => root.shown);
            if (typed === root.shown) return;
            root.applyKey(typed === "" ? null : typed);
        }
        actions: [
            IconButton {
                iconName: "x"
                label: "Unbind"
                size: "sm"
                visible: root.editable && root.bind.key !== null
                onClicked: root.applyKey(null)
            },
            IconButton {
                iconName: "rotate-ccw"
                label: "Reset to " + root.bind["default"]
                size: "sm"
                visible: root.editable && root.bind.key !== root.bind["default"]
                onClicked: root.applyKey(undefined)
            }
        ]
    }
}
