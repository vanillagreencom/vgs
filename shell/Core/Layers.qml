pragma Singleton
import QtQuick
import Quickshell

// The passive layers plugins draw in. A plugin's `layers` capability calls
// `show` with a Component of its own; the layer host builds that component
// once per screen inside a core-owned surface that never takes keyboard
// focus, and destroys every copy when the plugin releases it or its
// instance goes. The plugin keeps its state; the component reads it
// through the ids of the file that declares it.
Singleton {
    id: root

    // One registration per `show`, in registration order: { serial,
    // pluginId, component, screens }. `screens` is the host's record of what
    // it built, screen name -> that screen's copy of the content; it changes
    // without replacing the list.
    property var entries: []
    property int serial: 0
    // The entries' serials, the host's model: Variants copies a JS object it
    // is handed, so it is keyed by a value and looks the entry up.
    readonly property var serials: entries.map(e => e.serial)

    // Emitted with an entry's serial before it leaves `entries`, so the host
    // destroys its content while the plugin that declared the component
    // still exists.
    signal released(int serial)

    // Show `component` on every screen for the instance `ctx` belongs to;
    // answers the disposer. A component that cannot be built now is refused.
    function show(ctx, component) {
        if (component === null || typeof component !== "object" || typeof component.createObject !== "function")
            throw new Error("refused: layers=not-a-component");
        if (component.status !== Component.Ready)
            throw new Error("refused: layers=component-not-ready status=" + component.status);
        serial += 1;
        const entry = { serial: serial, pluginId: ctx.id, component: component, screens: {} };
        entries = entries.concat([entry]);
        return ctx.onDispose(() => root.remove(entry));
    }

    function entryOf(serial) {
        return entries.find(e => e.serial === serial) || null;
    }

    function remove(entry) {
        if (entries.indexOf(entry) === -1) return;
        released(entry.serial);
        entries = entries.filter(e => e !== entry);
    }

    // Every registration by plugin, with the screens it is built on.
    function record() {
        return entries.map(e => ({ plugin: e.pluginId, screens: Object.keys(e.screens).sort() }));
    }
}
