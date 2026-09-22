import QtQuick
import qs.Core

// One plugin instance of one kind inside a host. Owns the whole lifecycle:
// builds through the core, rebuilds when the plugin id or the plugin
// generation changes, destroys before every rebuild and on its own
// destruction. Every host is a surface plus one of these per plugin.
Item {
    id: slot

    required property string kind
    property string pluginId: ""
    // Names this slot in the core's build records; the smoke reads them.
    property string hostKey: ""
    // Host-owned properties the core assigns to the instance by name.
    property var context: ({})
    property var instance: null
    property string loadedKey: ""

    // Emitted with the key whose build produced no instance, so a host can
    // take the surface down instead of showing an empty one.
    signal buildFailed(string key)

    readonly property string key: Plugins.slotKey(pluginId)

    onKeyChanged: reload()
    Component.onCompleted: reload()
    Component.onDestruction: unload()

    function unload() {
        if (instance !== null) { Plugins.destroyInstance(instance, hostKey); instance = null; }
        loadedKey = "";
    }

    function reload() {
        if (key === loadedKey) return;
        unload();
        if (key === "") return;
        instance = Plugins.createInstance(pluginId, kind, slot, hostKey, null, context);
        if (instance === null) { buildFailed(key); return; }
        instance.anchors.fill = slot;
        loadedKey = key;
    }
}
