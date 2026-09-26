pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Polkit
import "PluginLogic.js" as Logic
import "Dispatch.js" as Dispatch

// Maps declared capabilities to per-instance providers and accounts for
// their holds. Resource owners implement registration and teardown.
Singleton {
    id: root

    // Capability name -> { plugin id -> number of live instances holding
    // it }, replaced whole on every change so bindings re-evaluate once.
    property var held: ({})

    ShortcutRegistry { id: shortcuts }
    IpcRegistry { id: commands }
    NotificationHub { id: notifications; active: root.notificationsHeld }
    SessionLock { id: sessionLock }
    readonly property alias sessionLock: sessionLock

    readonly property bool notificationsHeld: holderIds("notifications").length > 0
    readonly property bool polkitHeld: holderIds("polkit").length > 0

    function holderIds(name) {
        return Logic.hasOwn(held, name) ? Object.keys(held[name]).sort() : [];
    }

    // { capability -> plugin id } for every exclusive capability held.
    function exclusiveHolders() {
        const out = {};
        for (const name of Logic.EXCLUSIVE_CAPABILITIES) {
            const ids = holderIds(name);
            if (ids.length > 0) out[name] = ids[0];
        }
        return out;
    }

    function acquire(name, id) {
        const next = Logic.clone(held);
        if (!Logic.hasOwn(next, name)) next[name] = {};
        next[name][id] = (next[name][id] || 0) + 1;
        held = next;
    }

    function release(name, id) {
        if (!Logic.hasOwn(held, name) || !Logic.hasOwn(held[name], id))
            throw new Error("capabilities: release of " + name + " by " + id + " which holds none");
        const next = Logic.clone(held);
        next[name][id] -= 1;
        if (next[name][id] === 0) delete next[name][id];
        if (Object.keys(next[name]).length === 0) delete next[name];
        held = next;
    }

    // The providers for one instance: one per capability its manifest
    // names. `ctx` is { id, manifest, kind, hostKey, screen, locator,
    // onDispose(fn) }, `locator` being a bar widget's { section, nth }; every
    // hold and registration is released through ctx.onDispose.
    function providersFor(ctx) {
        const out = {};
        for (const name of ctx.manifest.capabilities) {
            if (!Logic.hasOwn(factories, name))
                throw new Error("capabilities: " + name + " is in PluginLogic.CAPABILITIES but has no provider");
            acquire(name, ctx.id);
            ctx.onDispose(() => root.release(name, ctx.id));
            out[name] = factories[name](ctx);
        }
        return out;
    }

    // Registration names a plugin chooses: lower case, digits and dashes.
    function checkName(kind, name) {
        if (typeof name !== "string" || !/^[a-z0-9][a-z0-9-]*$/.test(name))
            throw new Error("refused: " + kind + "=" + JSON.stringify(name) + " malformed");
    }

    readonly property var factories: ({
        compositor: ctx => {
            const out = {};
            for (const name of Dispatch.PLUGIN_DISPATCHERS)
                out[name] = (...args) => Compositor.send(name, args);
            return out;
        },
        configure: ctx => ({
            set: (key, value) => Plugins.writeSetting(ctx.id, key, value, [Logic.settingTargetOf(ctx.kind)], ctx.locator)
        }),
        ipc: commands.provider,
        lock: sessionLock.provider,
        notifications: notifications.provider,
        polkit: ctx => ({
            get agent() { return polkitLoader.item; },
            get registered() { return polkitLoader.item !== null && polkitLoader.item.isRegistered; }
        }),
        run: ctx => ({
            detached: argv => root.runDetached(argv)
        }),
        screens: ctx => ({
            get all() { return Quickshell.screens; },
            current: ctx.screen
        }),
        shortcut: shortcuts.provider,
        manager: ctx => ({
            get plugins() { return Registry.managerRows; },
            setEnabled: (id, enabled) => typeof enabled === "boolean" ? Plugins.setEnabled(id, enabled) : "refused: enabled=" + JSON.stringify(enabled) + " want=boolean",
            setSetting: (id, key, value) => Plugins.setSetting(id, key, value)
        }),
        builtins: ctx => ({
            register: (name, item) => Plugins.recordBuiltin(ctx, name, item)
        }),
        surfaces: ctx => ({
            summon: (kind, payloadJson, anchor) => Plugins.route("summon", kind, ctx.id, payloadJson || "", root.origin(ctx, anchor)),
            hide: kind => Plugins.route("hide", kind, ctx.id, "", null),
            toggle: (kind, payloadJson, anchor) => Plugins.route("toggle", kind, ctx.id, payloadJson || "", root.origin(ctx, anchor))
        })
    })

    // The compositor places anchored surfaces relative to the item's own
    // window. An instance without a screen uses the focused monitor.
    function origin(ctx, anchor) {
        if (anchor === undefined || anchor === null) return ctx.screen ? { anchor: null, screen: ctx.screen } : null;
        return { anchor: anchor, screen: ctx.screen };
    }

    // run: a detached process from an argument list. No shell parses it.
    // `ok` means the list was handed to Quickshell; a program that fails to
    // start is not reported back.
    function runDetached(argv) {
        if (!Array.isArray(argv) || argv.length === 0 || argv.some(a => typeof a !== "string" || a.length === 0))
            return "refused: argv=" + JSON.stringify(argv);
        Quickshell.execDetached(argv);
        return "ok";
    }

    LazyLoader {
        id: polkitLoader
        active: root.polkitHeld
        PolkitAgent {}
    }

    // Every capability's live state, for the validation rows and for
    // diagnosing a plugin: who holds what, and which core objects exist.
    function lentJson() {
        const holders = {};
        for (const name of Object.keys(held)) holders[name] = holderIds(name);
        return JSON.stringify({
            holders: holders,
            shortcuts: Object.keys(shortcuts.shortcuts).sort(),
            ipcTargets: Object.keys(commands.ipcTargets).sort(),
            subscribers: notifications.subscribers.map(s => s.id),
            notificationServer: notifications.server !== null,
            polkitAgent: polkitLoader.item !== null,
            polkitRegistered: polkitLoader.item !== null && polkitLoader.item.isRegistered,
            lock: { requested: sessionLock.lockRequested, secure: sessionLock.lockSecure, content: sessionLock.lockContent !== null }
        });
    }
}
