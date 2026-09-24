pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Notifications
import Quickshell.Services.Polkit
import "PluginLogic.js" as Logic

// The provider behind every capability name in PluginLogic.CAPABILITIES.
// Plugins.qml asks for one plugin instance's providers when it builds the
// instance; each provider is made for that instance, and every object it
// registers (a shortcut, an IPC target, a notification subscriber, a hold
// on the lock or the polkit agent) is released by a disposer the instance's
// build record runs when the instance is destroyed. The notification
// server and the polkit agent exist only while some plugin holds their
// capability, so a shell with no such plugin claims neither D-Bus role.
Singleton {
    id: root

    // Capability name -> { plugin id -> number of live instances holding
    // it }, replaced whole on every change so bindings re-evaluate once.
    property var held: ({})

    // Registered shortcuts, "<plugin id>:<name>" -> GlobalShortcut.
    property var shortcuts: ({})
    // IPC targets, plugin id -> { handler: IpcHandler, functions: { name -> fn } }.
    property var ipcTargets: ({})
    // Notification subscribers, in subscription order: { id, fn }.
    property var subscribers: []

    // The session lock the plugin holding `lock` asked for, the component
    // it draws on every screen, and whether the compositor confirmed it.
    property bool lockRequested: false
    property var lockContent: null
    property bool lockSecure: false
    // The instance context that handed over lockContent.
    property var lockContentOwner: null

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
        const next = JSON.parse(JSON.stringify(held));
        if (!Logic.hasOwn(next, name)) next[name] = {};
        next[name][id] = (next[name][id] || 0) + 1;
        held = next;
    }

    function release(name, id) {
        if (!Logic.hasOwn(held, name) || !Logic.hasOwn(held[name], id))
            throw new Error("capabilities: release of " + name + " by " + id + " which holds none");
        const next = JSON.parse(JSON.stringify(held));
        next[name][id] -= 1;
        if (next[name][id] === 0) delete next[name][id];
        if (Object.keys(next[name]).length === 0) delete next[name];
        held = next;
    }

    // The providers for one instance: one per capability its manifest
    // names. `ctx` is { id, manifest, kind, hostKey, screen, onDispose(fn) }; every
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
        compositor: ctx => ({
            focusWorkspace: workspace => Compositor.send("focusWorkspace", [workspace]),
            focusWindow: address => Compositor.send("focusWindow", [address]),
            moveWindowToWorkspace: (address, workspace) => Compositor.send("moveWindowToWorkspace", [address, workspace]),
            toggleSpecialWorkspace: name => Compositor.send("toggleSpecialWorkspace", [name]),
            closeWindow: address => Compositor.send("closeWindow", [address])
        }),
        configure: ctx => ({
            set: (key, value) => Plugins.writeSetting(ctx.id, key, value, [ctx.kind === "bar-widget" ? "layout" : "plugins"])
        }),
        ipc: ctx => ({
            handle: (name, fn) => root.handleIpc(ctx, name, fn)
        }),
        lock: ctx => {
            ctx.onDispose(() => root.dropLock(ctx));
            return {
                lock: content => root.lock(ctx, content),
                unlock: () => root.unlock(),
                get locked() { return root.lockRequested; },
                get secure() { return root.lockSecure; }
            };
        },
        notifications: ctx => ({
            subscribe: fn => root.subscribe(ctx, fn),
            get tracked() { return notificationLoader.item ? notificationLoader.item.trackedNotifications : null; }
        }),
        polkit: ctx => ({
            get agent() { return polkitLoader.item; }
        }),
        run: ctx => ({
            detached: argv => root.runDetached(argv)
        }),
        screens: ctx => ({
            get all() { return Quickshell.screens; },
            current: ctx.screen
        }),
        shortcut: ctx => ({
            register: (name, description, onPressed) => root.registerShortcut(ctx, name, description, onPressed)
        }),
        manager: ctx => ({
            get plugins() { return Plugins.managerRows; },
            setEnabled: (id, enabled) => Plugins.setEnabled(id, enabled === true),
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

    // Where a plugin summons its own surface from: this instance's screen,
    // and the rectangle of `anchor`, an item of the plugin's, in its
    // window's coordinates. A bar spans its screen from the top-left
    // corner, so for an item in a bar those are screen coordinates too.
    function origin(ctx, anchor) {
        if (anchor === undefined || anchor === null) return ctx.screen ? { anchor: null, screen: ctx.screen } : null;
        const at = anchor.mapToItem(null, 0, 0);
        return { anchor: { x: at.x, y: at.y, width: anchor.width, height: anchor.height }, screen: ctx.screen };
    }

    // shortcut: one GlobalShortcut per name under the plugin id, bound in
    // Hyprland as `global, <plugin id>:<name>`. A second registration of
    // the same name throws.
    function registerShortcut(ctx, name, description, onPressed) {
        checkName("shortcut", name);
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
        let live = true;
        const dispose = () => {
            if (!live) return;
            live = false;
            const rest = Object.assign({}, root.shortcuts);
            delete rest[key];
            root.shortcuts = rest;
            shortcut.destroy();
        };
        ctx.onDispose(dispose);
        return dispose;
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

    // ipc: one IpcHandler per plugin, target named for the plugin id, with
    // one function: `invoke <name> <arg>` calls the handler the plugin
    // registered under that name and answers its return value as text.
    function handleIpc(ctx, name, fn) {
        checkName("ipc", name);
        if (typeof fn !== "function")
            throw new Error("refused: ipc=" + name + " handler=not-a-function");
        let target = ipcTargets[ctx.id];
        if (target !== undefined && Logic.hasOwn(target.functions, name))
            throw new Error("refused: ipc=" + ctx.id + ":" + name + " held");
        const next = Object.assign({}, ipcTargets);
        if (target === undefined)
            target = { handler: ipcComponent.createObject(root, { target: ctx.id }), functions: {} };
        target = { handler: target.handler, functions: Object.assign({}, target.functions) };
        target.functions[name] = fn;
        next[ctx.id] = target;
        ipcTargets = next;
        let live = true;
        const dispose = () => {
            if (!live) return;
            live = false;
            const rest = Object.assign({}, root.ipcTargets);
            const t = { handler: rest[ctx.id].handler, functions: Object.assign({}, rest[ctx.id].functions) };
            delete t.functions[name];
            if (Object.keys(t.functions).length === 0) {
                t.handler.destroy();
                delete rest[ctx.id];
            } else {
                rest[ctx.id] = t;
            }
            root.ipcTargets = rest;
        };
        ctx.onDispose(dispose);
        return dispose;
    }

    function invokeIpc(id, name, arg) {
        const target = ipcTargets[id];
        if (target === undefined || !Logic.hasOwn(target.functions, name)) return "unknown: " + name;
        try {
            const result = target.functions[name](arg);
            return result === undefined ? "" : String(result);
        } catch (e) {
            console.error("capabilities: ipc " + id + ":" + name + " threw: " + e.message);
            return "error: " + e.message;
        }
    }

    Component {
        id: ipcComponent
        IpcHandler {
            function invoke(name: string, arg: string): string { return root.invokeIpc(target, name, arg); }
        }
    }

    // run: a detached process from an argument list. No shell parses it.
    function runDetached(argv) {
        if (!Array.isArray(argv) || argv.length === 0 || argv.some(a => typeof a !== "string" || a.length === 0))
            return "refused: argv=" + JSON.stringify(argv);
        Quickshell.execDetached(argv);
        return "ok";
    }

    // notifications: the one server, fanned out to every subscriber in
    // subscription order. A subscriber sets `tracked` on a notification it
    // keeps; one nobody tracks is discarded by the server.
    function subscribe(ctx, fn) {
        if (typeof fn !== "function")
            throw new Error("refused: notifications=subscribe handler=not-a-function");
        const entry = { id: ctx.id, fn: fn };
        subscribers = subscribers.concat([entry]);
        let live = true;
        const dispose = () => {
            if (!live) return;
            live = false;
            root.subscribers = root.subscribers.filter(s => s !== entry);
        };
        ctx.onDispose(dispose);
        return dispose;
    }

    function fanOut(notification) {
        for (const s of subscribers) {
            try {
                s.fn(notification);
            } catch (e) {
                console.error("capabilities: notification subscriber of " + s.id + " threw: " + e.message);
            }
        }
    }

    LazyLoader {
        id: notificationLoader
        active: root.notificationsHeld
        NotificationServer {
            keepOnReload: false
            bodySupported: true
            actionsSupported: true
            imageSupported: true
            onNotification: n => root.fanOut(n)
        }
    }

    LazyLoader {
        id: polkitLoader
        active: root.polkitHeld
        PolkitAgent {}
    }

    // lock: the one session lock, drawn by LockHost. `content` is a
    // Component the holder owns; LockHost builds it once per screen and
    // assigns its `screen`.
    function lock(ctx, content) {
        if (content === null || content === undefined || typeof content.createObject !== "function")
            return "refused: lock-content=not-a-component";
        lockContentOwner = ctx;
        lockContent = content;
        lockRequested = true;
        return "ok";
    }

    function unlock() {
        lockRequested = false;
        return "ok";
    }

    // An instance of the holder is gone. The content it handed over goes
    // with it, but a locked session stays locked: unloading the lock screen
    // never unlocks the desktop.
    function dropLock(ctx) {
        if (lockContentOwner !== ctx) return;
        lockContentOwner = null;
        lockContent = null;
    }

    // Every capability's live state, for the validation rows and for
    // diagnosing a plugin: who holds what, and which core objects exist.
    function lentJson() {
        const holders = {};
        for (const name of Object.keys(held)) holders[name] = holderIds(name);
        return JSON.stringify({
            holders: holders,
            shortcuts: Object.keys(shortcuts).sort(),
            ipcTargets: Object.keys(ipcTargets).sort(),
            subscribers: subscribers.map(s => s.id),
            notificationServer: notificationLoader.item !== null,
            polkitAgent: polkitLoader.item !== null,
            lock: { requested: lockRequested, secure: lockSecure, content: lockContent !== null }
        });
    }
}
