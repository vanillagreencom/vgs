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
    IdleRegistry { id: idleWatches }
    IpcRegistry { id: commands }
    NotificationHub { id: notifications; active: root.notificationsHeld }
    SessionLock { id: sessionLock }
    ThemeRunner { id: themes }
    TuiRunner { id: tuis }
    SecretWriter { id: secrets }
    SystemSteps { id: systemSteps; active: root.systemHeld }
    HyprlandState {
        id: hyprlandState
        active: root.holderIds("hyprland").length > 0 || hyprlandState.touchpadsWanted
    }
    readonly property alias sessionLock: sessionLock
    readonly property alias themes: themes
    readonly property alias tuis: tuis
    readonly property alias hyprland: hyprlandState

    readonly property bool notificationsHeld: holderIds("notifications").length > 0
    // `<plugin id>:<name>` -> the description each registered shortcut
    // carries, for the plugin manager's Keys rows.
    readonly property var shortcutDescriptions: {
        const out = {};
        for (const key of Object.keys(shortcuts.shortcuts)) out[key] = shortcuts.shortcuts[key].description;
        return out;
    }
    readonly property bool polkitHeld: holderIds("polkit").length > 0
    readonly property bool systemHeld: holderIds("system").length > 0
    property int polkitFlows: 0

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
        if (typeof name !== "string" || !Logic.NAME_PATTERN.test(name))
            throw new Error("refused: " + kind + "=" + JSON.stringify(name) + " malformed");
    }

    readonly property var factories: ({
        compositor: ctx => {
            const out = {};
            for (const name of Dispatch.PLUGIN_DISPATCHERS)
                out[name] = (...args) => Compositor.send(name, args);
            out.reveal = (addresses, awaitSender) => Compositor.reveal(addresses, awaitSender);
            return out;
        },
        configure: ctx => ({
            set: (key, value) => Plugins.writeSetting(ctx.id, key, value, [Logic.settingTargetOf(ctx.kind)], ctx.locator)
        }),
        idle: idleWatches.provider,
        ipc: commands.provider,
        lock: sessionLock.provider,
        session: sessionLock.sessionProvider,
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
            setPlaced: (id, placed) => typeof placed === "boolean" ? Plugins.setPlaced(id, placed) : "refused: placed=" + JSON.stringify(placed) + " want=boolean",
            setSetting: (id, key, value) => Plugins.setSetting(id, key, value),
            setKey: (id, shortcut, key) => Plugins.setKey(id, shortcut, key),
            update: id => root.managerTui("update", id),
            remove: id => root.managerTui("remove", id),
            installRequirements: id => Notices.requested(id),
            add: () => root.managerCoreTui("plugin-add", []),
            act: (id, key) => root.managerAct(id, key),
            storeSecret: (id, key, account, secret, done) => root.managerSecret(ctx, "store", id, key, account, secret, done),
            clearSecret: (id, key, account, done) => root.managerSecret(ctx, "clear", id, key, account, null, done)
        }),
        builtins: ctx => ({
            register: (name, item) => Plugins.recordBuiltin(ctx, name, item)
        }),
        surfaces: ctx => ({
            summon: (kind, payloadJson, anchor) => Plugins.route("summon", kind, ctx.id, payloadJson || "", root.origin(ctx, anchor)),
            hide: kind => Plugins.route("hide", kind, ctx.id, "", null),
            toggle: (kind, payloadJson, anchor) => Plugins.route("toggle", kind, ctx.id, payloadJson || "", root.origin(ctx, anchor))
        }),
        toasts: ctx => ({
            show: options => Toasts.show(ctx, options)
        }),
        layers: ctx => ({
            show: component => Layers.show(ctx, component)
        }),
        status: ctx => ({
            set: (key, value) => PluginStatus.set(ctx, key, value),
            get values() { return PluginStatus.valuesOf(ctx.id); },
            get revision() { return PluginStatus.revisionOf(ctx.id); }
        }),
        theme: themes.provider,
        tui: tuis.provider,
        system: systemSteps.provider,
        secrets: secrets.provider,
        hyprland: hyprlandState.provider,
        // `missing`: the plugin's own requirement commands the last scan did
        // not find, in declaration order, a copy per read; bindable.
        requirements: ctx => ({
            offer: commands => Notices.offer(ctx, commands),
            get missing() { return Notices.missingOf(ctx.id).slice(); },
            get revision() { return Registry.requirementsRevision; }
        }),
        doctor: ctx => ({
            offer: (owner, commands) => Notices.chosen(owner, commands),
            get missing() { return Registry.enabledOwnerMissing(); }
        })
    })

    // Every `manager` TUI member opens a core TUI in a floating terminal,
    // so a question such as update's diff review stays a question (D007).
    // A focused live window is the same shown answer as a started launch.
    function managerTui(action, id) {
        const source = typeof id === "string" && Registry.has(id) ? Registry.sourceOf(Registry.manifests[id]) : null;
        const request = Logic.managerTui(action, id, source);
        return request.ok ? root.managerCoreTui(request.name, request.args) : request.answer;
    }

    // What the manager's steps judge plugin ID by: { manifest, enabled,
    // values }, its manifest as its settings apply it
    // (Registry.activeManifestOf) or null for an id no plugin has, whether
    // it is enabled and the status values it published.
    function managerSubject(id) {
        const known = typeof id === "string" && Registry.has(id);
        return { manifest: known ? Registry.activeManifestOf(id) : null, enabled: known && Registry.isEnabled(id), values: known ? PluginStatus.valuesOf(id) : {} };
    }

    // The manager's act on plugin ID's status entry KEY (D061): the
    // plugin's own declared TUI through TuiRunner.runFor, its own
    // requirement commands through the requirement notice after a scan, or
    // its own system step in the core TUI `core/system`, after whose end
    // the steps are probed again (D081), as
    // PluginLogic.statusActionRequest decides from its published values.
    function managerAct(id, key) {
        const subject = managerSubject(id);
        const request = Logic.statusActionRequest(subject.manifest, id, subject.enabled, subject.values, key);
        if (!request.ok) return request.answer;
        switch (request.kind) {
        case "tui": return tuis.runFor(id, request.name);
        case "install": return Notices.chosen(id, request.commands);
        case "system": return root.managerCoreTui("system", request.args, () => systemSteps.probe());
        }
        throw new Error("manager: action kind " + JSON.stringify(request.kind) + " is not one of tui, install, system");
    }

    // The manager's store or clear (VERB) of plugin ID's ACCOUNT, listed in
    // its status entry KEY (D061), through the one SecretWriter, as
    // PluginLogic.secretRequest decides; `done` belongs to CTX, the asking
    // instance. SECRET never enters a log line or an answer.
    function managerSecret(ctx, verb, id, key, account, secret, done) {
        if (done !== undefined && typeof done !== "function")
            throw new Error("refused: secret done=not-a-function");
        const subject = managerSubject(id);
        const request = Logic.secretRequest(subject.manifest, id, subject.enabled, subject.values, key, account, verb, secret);
        if (!request.ok) return request.answer;
        return secrets.write(ctx, id, account, verb, request, done);
    }

    // Opens the core TUI `core/<name>` for the manager and returns the
    // shared shown answer from PluginLogic.tuiShownAnswer; `done`, when
    // given, receives the run's end as TuiRunner.openCore hands it.
    function managerCoreTui(name, args, done) {
        const key = "core/" + name;
        return Logic.tuiShownAnswer(key, tuis.openCore(name, args, done));
    }

    // The compositor places anchored surfaces relative to the item's own
    // window. An instance without a screen uses the focused monitor.
    function origin(ctx, anchor) {
        if (anchor === undefined || anchor === null) return ctx.screen ? { anchor: null, screen: ctx.screen } : null;
        return { anchor: anchor, screen: ctx.screen };
    }

    // run: a detached process from an argument list. No shell parses it.
    // `ok` means the list was handed to Quickshell; a program that fails to
    // start is not reported back. The program does not inherit
    // VGSH_RUNNER_PID, the variable that marks the shell's own processes: a
    // terminal the user opens from the shell is not the shell, and
    // `vgsh pkg run` refuses a caller that carries it (packages.md). A null
    // value removes a variable from the inherited environment.
    function runDetached(argv) {
        if (!Array.isArray(argv) || argv.length === 0 || argv.some(a => typeof a !== "string" || a.length === 0))
            return "refused: argv=" + JSON.stringify(argv);
        Quickshell.execDetached({ command: argv, environment: { VGSH_RUNNER_PID: null } });
        return "ok";
    }

    LazyLoader {
        id: polkitLoader
        active: root.polkitHeld
        // Each request that went live, counted for the lending record, so
        // a validation row can read that none ever did.
        PolkitAgent {
            onIsActiveChanged: if (isActive) root.polkitFlows += 1
        }
    }

    // Every capability's live state, for the validation rows and for
    // diagnosing a plugin: who holds what, and which core objects exist.
    function lentJson() {
        const holders = {};
        for (const name of Object.keys(held)) holders[name] = holderIds(name);
        return JSON.stringify({
            holders: holders,
            shortcuts: Object.keys(shortcuts.shortcuts).sort(),
            idle: idleWatches.record(),
            ipcTargets: Object.keys(commands.ipcTargets).sort(),
            subscribers: notifications.subscribers.map(s => s.id),
            notificationServer: notifications.server !== null,
            polkitAgent: polkitLoader.item !== null,
            polkitRegistered: polkitLoader.item !== null && polkitLoader.item.isRegistered,
            polkitFlows: root.polkitFlows,
            lock: { requested: sessionLock.lockRequested, secure: sessionLock.lockSecure, content: sessionLock.lockContent !== null },
            toasts: Toasts.record(),
            layers: Layers.record(),
            status: PluginStatus.record(),
            theme: themes.record(),
            tui: tuis.record(),
            system: systemSteps.record(),
            notices: Notices.record(),
            hyprland: hyprlandState.record()
        });
    }
}
