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
    // The screen the instance draws on, when the host knows one the
    // context does not carry.
    property var screen: null
    property var instance: null
    property string loadedKey: ""
    // The host key the instance was built under. A host's key can change
    // while it is torn down (its screen reads null), so the instance is
    // destroyed under this one.
    property string loadedHostKey: ""
    // Call the instance's close() before destroying it: a summoned kind's
    // host sets it, so a plugin closed by hide or by being disabled hears it.
    property bool closeOnUnload: false

    // Emitted with the key whose build produced no instance, so a host can
    // take the surface down instead of showing an empty one.
    signal buildFailed(string key)
    // Emitted with every instance the slot builds.
    signal built(var instance)

    readonly property string key: Plugins.slotKey(pluginId)

    onKeyChanged: reload()
    Component.onCompleted: reload()
    Component.onDestruction: unload()

    function unload() {
        if (instance !== null) {
            if (closeOnUnload) {
                try {
                    instance.close();
                } catch (e) {
                    console.error("plugin slot: " + pluginId + " close() failed: " + e.message);
                }
            }
            Plugins.destroyInstance(instance, loadedHostKey);
            instance = null;
        }
        loadedKey = "";
        loadedHostKey = "";
    }

    function reload() {
        if (key === loadedKey) return;
        unload();
        if (key === "") return;
        instance = Plugins.createInstance(pluginId, kind, slot, hostKey, null, context, screen);
        if (instance === null) { buildFailed(key); return; }
        instance.anchors.fill = slot;
        loadedKey = key;
        loadedHostKey = hostKey;
        built(instance);
    }
}
