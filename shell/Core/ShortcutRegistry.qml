import QtQuick
import Quickshell
import Quickshell.Hyprland
import "PluginLogic.js" as Logic

// Owns shortcut registrations across plugin instances. Each registration
// belongs to its instance lifetime and releases its native object with it.
Scope {
    id: root
    property var shortcuts: ({})

    function provider(ctx) {
        return { register: (name, description, onPressed) => root.registerShortcut(ctx, name, description, onPressed) };
    }

    // shortcut: one GlobalShortcut per name under the plugin id, bound in
    // Hyprland as `global, <plugin id>:<name>`. A second registration of
    // the same name throws.
    function registerShortcut(ctx, name, description, onPressed) {
        Capabilities.checkName("shortcut", name);
        if (typeof onPressed !== "function")
            throw new Error("refused: shortcut=" + name + " handler=not-a-function");
        const key = ctx.id + ":" + name;
        if (Logic.hasOwn(shortcuts, key))
            throw new Error("refused: shortcut=" + key + " held");
        const shortcut = shortcutComponent.createObject(root, { appid: ctx.id, name: name, description: String(description || "") });
        shortcut.handler = onPressed;
        const next = Object.assign({}, shortcuts);
        next[key] = shortcut;
        shortcuts = next;
        return ctx.onDispose(() => {
            const rest = Object.assign({}, root.shortcuts);
            delete rest[key];
            root.shortcuts = rest;
            shortcut.destroy();
        });
    }

    // The `pressed` property shadows the `pressed` signal from script, so
    // the handler runs from the signal handler instead of a connect().
    Component {
        id: shortcutComponent
        GlobalShortcut {
            property var handler: null
            onPressed: handler()
        }
    }

}
