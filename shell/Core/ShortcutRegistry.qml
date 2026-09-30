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
        // REVISIT(D059): A compositor readback API could include later user overrides.
        return {
            get keys() { return Layer.shortcutKeys(Registry.hyprlandSections, ctx.id); },
            register: (name, description, onPressed, onReleased) => root.registerShortcut(ctx, name, description, onPressed, onReleased)
        };
    }

    // One registration owns the main GlobalShortcut and, for an onReleased
    // caller, its release companion. The instance owns one disposer for both.
    function registerShortcut(ctx, name, description, onPressed, onReleased) {
        Capabilities.checkName("shortcut", name);
        const shortcut = root.registerHeldShortcut(ctx.id, name, description, onPressed, onReleased);
        return ctx.onDispose(() => root.releaseShortcut(ctx.id + ":" + name, shortcut));
    }

    function registerCoreShortcut(appid, name, description, onPressed) {
        Capabilities.checkName("shortcut", name);
        registerHeldShortcut(appid, name, description, onPressed);
    }

    function registerHeldShortcut(appid, name, description, onPressed, onReleased) {
        if (typeof onPressed !== "function")
            throw new Error("refused: shortcut=" + name + " handler=not-a-function");
        if (onReleased !== undefined && typeof onReleased !== "function")
            throw new Error("refused: shortcut=" + name + " release-handler=not-a-function");
        const key = appid + ":" + name;
        if (Logic.hasOwn(shortcuts, key))
            throw new Error("refused: shortcut=" + key + " held");
        const shortcut = shortcutComponent.createObject(root, { appid: appid, name: name, description: String(description || "") });
        shortcut.handler = onPressed;
        if (onReleased !== undefined) {
            shortcut.releaseHandler = onReleased;
            const companion = releaseComponent.createObject(shortcut, { appid: appid, name: Layer.releaseShortcutName(name), description: String(description || "") });
            companion.owner = shortcut;
            shortcut.companion = companion;
        }
        const next = Object.assign({}, shortcuts);
        next[key] = shortcut;
        shortcuts = next;
        return shortcut;
    }

    function releaseShortcut(key, shortcut) {
        const rest = Object.assign({}, root.shortcuts);
        delete rest[key];
        root.shortcuts = rest;
        try { shortcut.finish("disposed"); }
        finally { shortcut.destroy(); }
    }

    // The `pressed` property shadows the `pressed` signal from script, so
    // the handler runs from the signal handler instead of a connect().
    Component {
        id: shortcutComponent
        GlobalShortcut {
            id: shortcut
            property var handler: null
            property var releaseHandler: null
            property var companion: null
            property var stroke: ({ kind: "idle" })
            readonly property var effectiveKey: Layer.shortcutKeys(Registry.hyprlandSections, appid)[name]

            function finish(nextKind) {
                const held = stroke.kind === "held";
                stroke = { kind: nextKind };
                if (held) releaseHandler();
            }

            onEffectiveKeyChanged: {
                if (stroke.kind === "held" && stroke.key !== effectiveKey)
                    finish("idle");
            }

            onPressed: {
                if (stroke.kind === "disposed") return;
                if (releaseHandler === null) { handler(); return; }
                if (stroke.kind === "held") return;
                // Registry can change before Hyprland replaces its old binds.
                const key = Layer.shortcutKeys(Registry.hyprlandSections, appid)[name];
                if (key === null || key === undefined) return;
                stroke = { kind: "held", key: key };
                handler();
            }
            // Lua global dispatch can lose this object's native release
            // when the modifier mask changes. The companion owns that edge.
        }
    }

    Component {
        id: releaseComponent
        GlobalShortcut {
            property var owner: null
            onReleased: {
                if (owner.stroke.kind === "held") owner.finish("idle");
            }
        }
    }

}
