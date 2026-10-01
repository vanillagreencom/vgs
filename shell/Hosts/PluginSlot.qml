import QtQuick
import qs.Core

// One plugin instance of one kind inside a host. Owns the whole lifecycle:
// builds through the core, rebuilds when the plugin id or the plugin
// source revision changes, destroys before every rebuild and on its own
// destruction. Every host is a surface plus one of these per plugin.
FocusScope {
    id: slot

    required property string kind
    property string pluginId: ""
    // Names this slot in the core's build records; the smoke reads them.
    property string hostKey: ""
    // Host-owned properties the core assigns to the instance by name.
    property var context: ({})
    // The screen the instance draws on; null for a kind with no screen.
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
    property Item pendingFocusTarget: null
    property int pendingFocusReason: Qt.OtherFocusReason

    // Only code failures suppress a host until its source changes. A
    // temporary enablement or lending refusal must remain eligible to retry.
    signal buildFailed(string key)
    // Emitted with every instance the slot builds.
    signal built(var instance)

    readonly property string key: Registry.slotKey(pluginId)

    onKeyChanged: reload()
    Component.onCompleted: reload()
    Component.onDestruction: unload()

    function focusTarget() {
        let target = slot;
        if (instance !== null && instance.initialFocus !== undefined && instance.initialFocus !== null) target = instance.initialFocus;
        return typeof target.forceActiveFocus === "function" ? target : slot;
    }

    function keyFocusReason(reason) {
        return reason === Qt.ShortcutFocusReason || reason === Qt.TabFocusReason || reason === Qt.BacktabFocusReason;
    }

    function applyPendingFocus() {
        if (pendingFocusTarget === null) return;
        const target = pendingFocusTarget;
        const reason = pendingFocusReason;
        pendingFocusTarget = null;
        pendingFocusReason = Qt.OtherFocusReason;
        target.forceActiveFocus(reason);
    }

    function focusInitial(reason) {
        pendingFocusTarget = null;
        pendingFocusReason = Qt.OtherFocusReason;
        const target = focusTarget();
        const window = slot.Window.window;
        if (!keyFocusReason(reason) || (window !== null && window.active)) {
            target.forceActiveFocus(reason);
            return;
        }
        pendingFocusTarget = target;
        pendingFocusReason = reason;
    }

    Connections {
        id: windowFocusConnection
        target: slot.Window.window
        function onActiveChanged() {
            if (windowFocusConnection.target.active) slot.applyPendingFocus();
        }
    }

    function clearPendingFocus() {
        pendingFocusTarget = null;
        pendingFocusReason = Qt.OtherFocusReason;
    }

    function unload() {
        clearPendingFocus();
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
        // Lending changes take a refused key away, then restore it when the
        // capability becomes available. Settings alone do not trigger retries.
        loadedKey = key;
        const result = Plugins.createInstance(pluginId, kind, slot, hostKey, null, context, screen);
        if (result.state === "failed") { buildFailed(key); return; }
        if (result.state === "refused") return;
        instance = result.instance;
        instance.anchors.fill = slot;
        loadedHostKey = hostKey;
        built(instance);
    }
}
