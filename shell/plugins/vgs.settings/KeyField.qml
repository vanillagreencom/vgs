import QtQuick
import qs.Commons
import qs.Ui

// One row of a plugin's Keys section, from one bind the manager lists:
// the shortcut's name beside a ShortcutField holding the key in effect,
// with the description the plugin registered and the manifest's key under
// it. Pressing a combo, or typing one as `MOD+KEY`, sends that key, the
// field's unbind button sends null, which unbinds it, and the reset button
// sends undefined, which removes the shell.json entry so the manifest's
// key applies; the unbind and reset buttons show only where they change
// something. The field then shows what the configuration holds again, so
// a refused key leaves the old one in place. Under the field, a hint names
// every other plugin shortcut and user Hyprland bind that holds the same
// key, and says so when Hyprland's binds could not be read; it never stops
// the key being set.
Field {
    id: root

    property string pluginId: ""
    // { shortcut, key, default, description }; `key` is null while unbound.
    property var bind: ({})
    property bool editable: true
    // The `shortcut` capability's key capture member, or null.
    property var capture: null
    // The Settings window's row for a plugin id, or null: the hint names a
    // plugin holding the same key by its row's name.
    property var rowOf: id => null
    signal applyKey(var key)

    readonly property string shown: bind.key === null || bind.key === undefined ? "" : String(bind.key)
    readonly property string conflict: {
        if (capture === null || shown === "") return "";
        const found = capture.conflicts(shown, pluginId, String(bind.shortcut));
        const holders = found.plugins.map(p => nameOf(p.id) + " (" + p.shortcut + ")")
            .concat(found.user.map(d => d === "" ? "your Hyprland config" : "your Hyprland config (" + d + ")"));
        const held = holders.length === 0 ? "" : "Also bound to " + holders.join(", ") + ".";
        const unread = found.binds === "failed" ? "Your Hyprland binds could not be read, so another bind may hold this key." : "";
        return [held, unread].filter(line => line !== "").join(" ");
    }

    function nameOf(id) {
        const row = rowOf(id);
        return row === null ? id : row.name;
    }

    label: String(bind.shortcut)
    hint: (bind.description ? String(bind.description) + ". " : "") + (bind.key === bind["default"] ? "The manifest's key." : "The manifest's key is " + bind["default"] + ".")
    inline: true

    ShortcutField {
        id: input
        width: parent.width
        key: root.shown
        capture: root.capture
        editable: root.editable
        conflict: root.conflict
        onCommitted: key => root.applyKey(key)
        onTyped: text => root.applyKey(text === "" ? null : text)
        onCleared: root.applyKey(null)
        actions: [
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
