import QtQuick
import Quickshell
import Quickshell.Hyprland
import "PluginLogic.js" as Logic
import "HyprlandLayer.js" as Layer

// Owns shortcut registrations across plugin instances. Each registration
// belongs to its instance lifetime and releases its native object with it.
Scope {
    id: root
    property var shortcuts: ({})

    Component.onCompleted: {
        const capture = Layer.OVERLAY_CAPTURE;
        for (const direction of Layer.overlayCaptureDirections())
            registerCoreShortcut(capture.appid, capture.shortcuts[direction], "Navigate the open overlay " + direction, () => Plugins.navigateOverlay(direction));
    }

    function provider(ctx) {
        // REVISIT(D056): A compositor readback API could include later user overrides.
        return {
            get keys() { return Layer.shortcutKeys(Registry.hyprlandSections, ctx.id); },
            register: (name, description, onPressed) => root.registerShortcut(ctx, name, description, onPressed)
        };
    }

    // shortcut: one GlobalShortcut per name under the plugin id, bound in
    // Hyprland as `global, <plugin id>:<name>`. A second registration of
    // the same name throws.
    function registerShortcut(ctx, name, description, onPressed) {
        Capabilities.checkName("shortcut", name);
        const shortcut = root.registerHeldShortcut(ctx.id, name, description, onPressed);
        return ctx.onDispose(() => root.releaseShortcut(ctx.id + ":" + name, shortcut));
    }

    function registerCoreShortcut(appid, name, description, onPressed) {
        Capabilities.checkName("shortcut", name);
        registerHeldShortcut(appid, name, description, onPressed);
    }

    function registerHeldShortcut(appid, name, description, onPressed) {
        if (typeof onPressed !== "function")
            throw new Error("refused: shortcut=" + name + " handler=not-a-function");
        const key = appid + ":" + name;
        if (Logic.hasOwn(shortcuts, key))
            throw new Error("refused: shortcut=" + key + " held");
        const shortcut = shortcutComponent.createObject(root, { appid: appid, name: name, description: String(description || "") });
        shortcut.handler = onPressed;
        const next = Object.assign({}, shortcuts);
        next[key] = shortcut;
        shortcuts = next;
        return shortcut;
    }

    function releaseShortcut(key, shortcut) {
        const rest = Object.assign({}, root.shortcuts);
        delete rest[key];
        root.shortcuts = rest;
        shortcut.destroy();
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
