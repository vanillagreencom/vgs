pragma Singleton
import QtQuick
import Quickshell
import "PluginLogic.js" as Logic
import "Lifetime.js" as Lifetime

// Every live plugin instance. Builds each instance the hosts ask for from
// the Registry's manifests, mounts bar widgets into the active bar's
// sections, keeps every live instance's settings current, releases what
// an instance registered when it goes, owns enable, disable and a
// widget's placement, and answers the readbacks the validation rows use.
// Hosts call the slot API; they never build a plugin or assign a plugin
// property themselves.
Singleton {
    id: root

    // Hosts by kind, registered on completion. summon/hide/toggle route here.
    property var hosts: Object.create(null)

    // Every instance on a surface, keyed by a host-supplied key, for the
    // IPC introspection the smoke reads. A row is { id, kind, origin,
    // instance, capabilities, entry, settingsKey, providers, lifetime,
    // screen }: `origin` is "core" for an instance the core built and
    // "plugin" for an item a plugin drew itself and registered through its
    // `builtins` capability; `kind` is the built instance's kind, or the
    // registering instance's kind for a registered item; `entry` is a bar
    // widget's layout entry, `settingsKey` the JSON of the settings the
    // instance holds, `providers` the capability providers made for it, and
    // `lifetime` owns its pending releases.
    property var built: Object.create(null)
    // Per bar instance, the widgets the core mounted in each of its
    // sections, keyed by the bar's host key: { row, sections: { <section>:
    // { idsKey, entries } } }, `entries` one { key, widget } per wanted
    // layout entry, in order, `widget` null where the build failed, so a
    // later entry keeps its own settings. Not a binding input; read and
    // replaced only by the reconciler.
    property var mounts: Object.create(null)
    // JSON [hostKey, kind, id] -> { id, kind, revision, screenName, error }:
    // the source revision whose build failed at that address and why. A
    // settings change cannot repair code. The plugin manager lists `error`.
    // A source change or screen removal expires the record. Stored screen
    // names survive the destruction of the screen objects they identify.
    property var failedBuilds: Object.create(null)

    // The source revisions of every instance the core built, which a scan
    // keeps on disk while the instance lives.
    function liveRevisions() {
        const out = Object.create(null);
        for (const hostKey of Object.keys(built))
            for (const row of built[hostKey])
                if (row.origin === "core") out[row.revision] = true;
        return Object.keys(out);
    }

    // Every change reaches every live instance through one reconcile: a
    // configuration change at once; a settled lending change at once; a
    // registry change after the slots keyed on it have moved, having first
    // dropped the failure memory of plugins that are gone or changed.
    Connections {
        target: Config
        function onEffectiveChanged() { root.reconcile(); }
    }
    Connections {
        target: Registry
        function onLendingChanged() { root.reconcile(); }
        function onChanged() {
            root.pruneFailures();
            Qt.callLater(root.reconcile);
        }
    }
    Connections {
        target: Quickshell
        function onScreensChanged() { root.pruneFailures(); }
    }

    function pruneFailures() {
        const manifests = Registry.manifests;
        const screens = Quickshell.screens.map(screen => screen.name);
        const failures = Object.create(null);
        for (const key of Object.keys(failedBuilds)) {
            const failure = failedBuilds[key];
            if (Logic.hasOwn(manifests, failure.id) && manifests[failure.id].__revision === failure.revision
                && (failure.screenName === null || screens.indexOf(failure.screenName) !== -1))
                failures[key] = failure;
        }
        failedBuilds = failures;
    }

    // The scoped object a plugin receives as `shell`: its manifest, its
    // settings, and the providers made for this instance, one per capability
    // its manifest names. Nothing else on it. A settings change hands over a
    // new object holding the same providers.
    function facadeFor(manifest, settings, providers) {
        const facade = { manifest: manifest, settings: settings };
        for (const name of manifest.capabilities)
            facade[name] = providers[name];
        return facade;
    }

    // Build one plugin entry point under `parent` and hand it its own
    // facade. `context` holds host-owned properties the instance receives
    // by name (a bar's `screen`); `screen` is the screen the instance draws
    // on, which its `screens` capability reports, null for a kind with no
    // screen. Properties are assigned after creation, never as initial
    // properties, which cross a QVariant conversion that drops functions and
    // turns nested lists into non-Array sequences. Returns the attempt's
    // built, refused or failed state. A failure in the plugin's
    // own code is remembered for this host, kind and id; a refusal on
    // enablement or lending is not, since either can change independently.
    function createInstance(id, kind, parent, hostKey, layoutEntry, context, screen, locator) {
        const manifest = Registry.manifests[id];
        if (manifest === undefined) { console.error("plugins: unknown: " + id); return { state: "refused" }; }
        if (failedRevision(hostKey, kind, id) === manifest.__revision) return { state: "failed" };
        const result = attemptInstance(id, kind, parent, hostKey, layoutEntry, context, screen, locator);
        if (result.state === "failed") rememberFailure(hostKey, kind, id, manifest.__revision, screen, result.error);
        return result;
    }

    function failedRevision(hostKey, kind, id) {
        const key = JSON.stringify([hostKey, kind, id]);
        return Logic.hasOwn(failedBuilds, key) ? failedBuilds[key].revision : null;
    }

    function rememberFailure(hostKey, kind, id, revision, screen, error) {
        const failures = Object.assign(Object.create(null), failedBuilds);
        failures[JSON.stringify([hostKey, kind, id])] = { id: id, kind: kind, revision: revision, screenName: screen ? screen.name : null, error: error };
        failedBuilds = failures;
    }

    // One build attempt: { state: "built", instance }, { state: "refused" }
    // when enablement or exclusive lending stands in the way, or
    // { state: "failed", error } when the plugin's manifest or code does,
    // `error` being the logged cause without the plugin's id.
    function attemptInstance(id, kind, parent, hostKey, layoutEntry, context, screen, locator) {
        const refused = { state: "refused" };
        const failed = error => {
            console.error("plugins: " + id + " " + error);
            return { state: "failed", error: error };
        };
        const enable = Registry.enableRefusal(id);
        if (enable !== "") { console.error("plugins: " + enable); return refused; }
        const url = Registry.entryUrl(id, kind);
        if (url === "") return failed("declares no " + kind + " entry point");
        const manifest = Registry.manifests[id];
        const lent = Logic.lendRefusal(Capabilities.exclusiveHolders(), manifest);
        if (lent !== "") { console.error("plugins: " + id + " " + lent); return refused; }
        const component = Qt.createComponent(url);
        if (component.status !== Component.Ready) return failed("failed to load: " + component.errorString());
        const instance = component.createObject(parent);
        if (instance === null) return failed("created no object");
        if (!(instance instanceof Item)) {
            instance.destroy();
            return failed(kind + " not built: entry point must be an Item");
        }
        const settings = Logic.settingsFor(Config.effective, manifest, Logic.settingTargetOf(kind), layoutEntry);
        const onScreen = screen !== undefined && screen !== null ? screen : null;
        const row = { id: id, kind: kind, origin: "core", revision: manifest.__revision, instance: instance, capabilities: manifest.capabilities, entry: layoutEntry, settingsKey: JSON.stringify(settings), providers: {}, lifetime: Lifetime.create(e => console.error("plugins: " + id + " disposer failed: " + e.message)), screen: onScreen };
        try {
            row.providers = Capabilities.providersFor({ id: id, manifest: manifest, kind: kind, hostKey: hostKey, screen: onScreen, locator: locator || null, onDispose: row.lifetime.register });
        } catch (e) {
            row.lifetime.drain();
            instance.destroy();
            return failed("capabilities failed: " + e.message);
        }
        try {
            instance.shell = facadeFor(manifest, settings, row.providers);
            for (const key of Object.keys(context || {}))
                instance[key] = context[key];
            record(hostKey, row);
            if (kind === "bar") mountBar(hostKey, row);
        } catch (e) {
            const error = failed(kind + " not built: " + e.message);
            if (kind === "bar" && Logic.hasOwn(mounts, hostKey) && mounts[hostKey].row === row) unmountBar(hostKey);
            if (Logic.hasOwn(built, hostKey) && built[hostKey].indexOf(row) !== -1) destroyBuilt(hostKey, instance);
            else {
                row.lifetime.drain();
                instance.destroy();
            }
            return error;
        }
        return { state: "built", instance: instance };
    }

    // A bar widget: built like any instance on its bar's screen, then given
    // the three properties BarWidget declares. `locator` is { section, nth }:
    // which layout entry with this id the widget reads, for its configure
    // capability. A widget that does not declare them is destroyed.
    function createWidget(id, parent, barRow, entry, hostKey, locator) {
        const result = createInstance(id, "bar-widget", parent, hostKey, entry, null, barRow.screen, locator);
        if (result.state !== "built") return null;
        const instance = result.instance;
        try {
            instance.bar = barRow.instance;
            instance.moduleName = id;
            instance.settings = instance.shell.settings;
        } catch (e) {
            const error = "bar-widget not built: " + e.message;
            console.error("plugins: " + id + " " + error);
            destroyBuilt(hostKey, instance);
            rememberFailure(hostKey, "bar-widget", id, Registry.manifests[id].__revision, barRow.screen, error);
            return null;
        }
        return instance;
    }

    // Destroy an instance the core built. A bar's mounted widgets go first,
    // so a bar never outlives the core's record of what it shows.
    function destroyInstance(instance, hostKey) {
        if (instance === null || instance === undefined) return;
        if (Logic.hasOwn(mounts, hostKey) && mounts[hostKey].row.instance === instance) unmountBar(hostKey);
        destroyBuilt(hostKey, instance);
    }

    // Release everything one instance registered, newest first, then forget
    // and destroy it. A disposer that throws is logged and the rest still run.
    function destroyBuilt(hostKey, instance) {
        const row = Logic.hasOwn(built, hostKey) ? rowFor(hostKey, instance) : undefined;
        if (row === undefined) throw new Error("plugins: destroying an instance with no build record under " + hostKey);
        row.lifetime.drain();
        forget(hostKey, instance);
        instance.destroy();
    }

    function record(hostKey, row) {
        const next = Object.assign(Object.create(null), built);
        next[hostKey] = (next[hostKey] || []).concat([row]);
        built = next;
    }

    // Record a widget a plugin draws itself (a bar's clock) under the
    // plugin's host key as `<plugin id>/<name>`, origin `plugin` and the
    // registering instance's kind, so the build records list everything on
    // the surface. The core built none of it, so the build counter does not
    // move. Returns the disposer, which the plugin calls when the widget
    // goes and the core calls when the plugin's instance goes.
    function recordBuiltin(ctx, name, item) {
        Capabilities.checkName("builtin", name);
        const id = ctx.id + "/" + name;
        if (Logic.hasOwn(built, ctx.hostKey) && built[ctx.hostKey].some(r => r.id === id))
            throw new Error("refused: builtin=" + id + " held host=" + ctx.hostKey);
        record(ctx.hostKey, { id: id, kind: ctx.kind, origin: "plugin", instance: item, capabilities: [], entry: null, settingsKey: "", providers: {}, lifetime: null, screen: ctx.screen });
        return ctx.onDispose(() => root.forget(ctx.hostKey, item));
    }

    function forget(hostKey, instance) {
        if (!Logic.hasOwn(built, hostKey)) return;
        const next = Object.assign(Object.create(null), built);
        next[hostKey] = next[hostKey].filter(row => row.instance !== instance);
        if (next[hostKey].length === 0) delete next[hostKey];
        built = next;
    }

    // The section containers a bar declares: `leftSection`, `centerSection`
    // and `rightSection`, each an Item the core parents widgets into. A bar
    // missing one is logged and that section shows nothing.
    function sectionContainer(row, section) {
        const container = row.instance[section + "Section"];
        if (container === null || container === undefined || typeof container !== "object") {
            console.error("plugins: bar " + row.id + " declares no " + section + "Section");
            return null;
        }
        return container;
    }

    function mountBar(hostKey, row) {
        const sections = {};
        for (const section of Logic.SECTIONS) sections[section] = { idsKey: "", entries: [] };
        const next = Object.assign(Object.create(null), mounts);
        next[hostKey] = { row: row, sections: sections };
        mounts = next;
        reconcileBar(hostKey, Logic.effectiveLayout(Config.effective, Registry.manifests, Registry.defaultBarId));
    }

    function unmountBar(hostKey) {
        const mount = mounts[hostKey];
        for (const section of Logic.SECTIONS)
            for (const entry of mount.sections[section].entries)
                if (entry.widget !== null) destroyBuilt(hostKey, entry.widget);
        const next = Object.assign(Object.create(null), mounts);
        delete next[hostKey];
        mounts = next;
    }

    // Bring one bar's sections to `layout`, the effective layout: the
    // widgets each section shows with enablement already applied. A section
    // whose id sequence changed is rebuilt whole, in order; a section whose
    // ids are unchanged keeps its widgets and only the entries that changed
    // are handed their new settings, so an unrelated write builds nothing.
    // The section's entries stay aligned with `wanted`, a failed build
    // included, so an edit to one entry reaches that entry's widget alone.
    function reconcileBar(hostKey, layout) {
        const mount = mounts[hostKey];
        const manifests = Registry.manifests;
        const holders = Capabilities.exclusiveHolders();
        for (const section of Logic.SECTIONS) {
            const wanted = layout[section].filter(e => Logic.lendRefusal(holders, manifests[e.id]) === "");
            const state = mount.sections[section];
            const idsKey = JSON.stringify(wanted.map(e => e.id));
            const entryKeys = wanted.map(e => JSON.stringify(e));
            if (idsKey !== state.idsKey) {
                for (const entry of state.entries)
                    if (entry.widget !== null) destroyBuilt(hostKey, entry.widget);
                state.entries = [];
                state.idsKey = "";
                const container = sectionContainer(mount.row, section);
                if (container === null) continue;
                const entries = [];
                for (let i = 0; i < wanted.length; i++) {
                    const nth = wanted.slice(0, i).filter(e => e.id === wanted[i].id).length;
                    const widget = createWidget(wanted[i].id, container, mount.row, wanted[i], hostKey, { section: section, nth: nth });
                    entries.push({ key: entryKeys[i], revision: manifests[wanted[i].id].__revision, widget: widget });
                }
                state.entries = entries;
                state.idsKey = idsKey;
                continue;
            }
            for (let i = 0; i < state.entries.length; i++) {
                const entry = state.entries[i];
                const revision = manifests[wanted[i].id].__revision;
                if (revision !== entry.revision) {
                    // This entry's source changed: rebuild it alone. A new
                    // child lands last in its section, so the widgets that
                    // follow it are re-parented behind it to keep the
                    // layout's order; stackBefore is not callable from QML.
                    if (entry.widget !== null) destroyBuilt(hostKey, entry.widget);
                    const container = sectionContainer(mount.row, section);
                    const nth = wanted.slice(0, i).filter(e => e.id === wanted[i].id).length;
                    entry.widget = container === null ? null : createWidget(wanted[i].id, container, mount.row, wanted[i], hostKey, { section: section, nth: nth });
                    entry.revision = revision;
                    if (entry.widget !== null)
                        for (const later of state.entries.slice(i + 1))
                            if (later.widget !== null) {
                                later.widget.parent = null;
                                later.widget.parent = container;
                            }
                }
                if (entryKeys[i] === entry.key) continue;
                entry.key = entryKeys[i];
                if (entry.widget !== null) refreshRow(rowFor(hostKey, entry.widget), wanted[i]);
            }
        }
    }

    function rowFor(hostKey, instance) {
        return built[hostKey].filter(row => row.instance === instance)[0];
    }

    // Hand one live instance the settings the configuration now holds for
    // it, when they changed. A bar widget's settings come from its layout
    // entry; every other kind's from its plugins[] row.
    function refreshRow(row, layoutEntry) {
        const manifest = Registry.manifests[row.id];
        const settings = Logic.settingsFor(Config.effective, manifest, Logic.settingTargetOf(row.kind), layoutEntry);
        const key = JSON.stringify(settings);
        row.entry = layoutEntry;
        if (key === row.settingsKey) return;
        row.settingsKey = key;
        row.instance.shell = facadeFor(manifest, settings, row.providers);
        if (row.kind === "bar-widget") row.instance.settings = settings;
    }

    // Bring every live instance to the current configuration: each bar's
    // sections to the effective layout, and every non-widget instance's
    // settings to its plugins[] row. The layout is derived here, inside the
    // change handler, because a binding on the same source would still be
    // stale at this point. Instances a slot is about to destroy are
    // refreshed for nothing; the slot forgets them next.
    function reconcile() {
        const layout = Logic.effectiveLayout(Config.effective, Registry.manifests, Registry.defaultBarId);
        for (const hostKey of Object.keys(mounts)) {
            try {
                reconcileBar(hostKey, layout);
            } catch (e) {
                console.error("plugins: reconciling " + hostKey + " failed: " + e.message);
            }
        }
        for (const hostKey of Object.keys(built)) {
            for (const row of built[hostKey]) {
                if (row.kind === "bar-widget" || row.origin === "plugin" || !Registry.has(row.id)) continue;
                try {
                    refreshRow(row, null);
                } catch (e) {
                    console.error("plugins: " + row.id + " settings not delivered: " + e.message);
                }
            }
        }
    }

    function builtJson() {
        const out = {};
        for (const key of Object.keys(built))
            out[key] = built[key].map(row => ({ id: row.id, kind: row.kind, origin: row.origin, capabilities: row.capabilities, pendingCleanups: row.lifetime === null ? 0 : row.lifetime.count }));
        return JSON.stringify(out);
    }

    // Kind-generic summon, hide and toggle for the summonable kinds. A host
    // registers itself under its kind on completion. `origin` is null for
    // an IPC call, which opens on the focused screen, or { anchor, screen }
    // for a plugin summoning its own surface. The reply is one keyed line.
    function registerHost(kind, host) {
        const next = Object.assign(Object.create(null), hosts);
        next[kind] = host;
        hosts = next;
    }

    function route(verb, kind, id, payloadJson, origin) {
        if (Logic.SUMMONABLE_KINDS.indexOf(kind) === -1) return "refused: not-summonable=" + kind;
        if (!Logic.hasOwn(hosts, kind)) return "refused: no-host=" + kind;
        if (!Registry.has(id)) return "unknown: " + id;
        if (Registry.manifests[id].kinds.indexOf(kind) === -1) return "refused: kind=" + kind + " id=" + id;
        if (verb === "hide") return hosts[kind].hide(id);
        const refusal = Registry.buildRefusal(id);
        if (refusal !== "") return refusal;
        return hosts[kind][verb](id, payloadJson, origin || null);
    }

    function navigateOverlay(direction) {
        if (!Logic.hasOwn(hosts, "overlay")) return "refused: no-host=overlay";
        return hosts.overlay.navigate(direction);
    }

    // Enable or disable one plugin. The reply is one keyed line the CLI
    // prints as is: `ok`, `ok hidden=<a,b>` when disabling the active bar
    // takes those widgets off the screen, `unknown: <id>`, or a refusal
    // naming why the user file was not written. Enabling a plugin that
    // misses a command it needs raises the requirement notice, whichever
    // caller asked: the IPC function, the CLI or the `manager` capability.
    function setEnabled(id, enabled) {
        if (!Registry.has(id)) return "unknown: " + id;
        const m = Registry.manifests[id];
        const hidden = enabled ? [] : Logic.hiddenByDisabling(Registry.manifests, Config.effective, id, Registry.defaultBarId);
        const written = Config.writeUser(Logic.withEnabled(Config.user, m, enabled, Config.effective));
        if (written !== "ok") return written;
        if (enabled) Notices.enabled(id);
        return hidden.length > 0 ? "ok hidden=" + hidden.join(",") : "ok";
    }

    // Show or hide plugin `id`'s widget in the bar (PluginLogic.withPlaced).
    // disabledPlugins is never written: a plugin with another kind stays
    // enabled and keeps its service and other kinds built, and a plugin
    // whose only kind is bar-widget reads disabled once unplaced. The reply is one keyed line the CLI prints as is: `ok` (the save is
    // queued), `unknown: <id>`, `refused: placed=<id>
    // reason=no-bar-widget|disabled` from PluginLogic.placedRefusal, or a
    // refusal naming why the user file was not written.
    function setPlaced(id, placed) {
        if (!Registry.has(id)) return "unknown: " + id;
        const m = Registry.manifests[id];
        const refusal = Logic.placedRefusal(Config.effective, m, Registry.defaultBarId);
        if (refusal !== "") return refusal;
        return Config.writeUser(Logic.withPlaced(Config.user, m, placed, Config.effective));
    }

    // Write one setting of one plugin into each configuration entry in
    // `targets` ("layout", "plugins"); `locator` { section, nth } narrows
    // "layout" to one entry. The value is checked against the manifest's
    // schema first. The reply is one keyed line: `ok` (the save is queued),
    // `unknown: <id>` or a refusal.
    function writeSetting(id, key, value, targets, locator) {
        if (!Registry.has(id)) return "unknown: " + id;
        const m = Registry.manifests[id];
        const refusal = Logic.settingRefusal(m, key, value);
        if (refusal !== "") return refusal;
        if (targets.length === 0) return "refused: setting=" + key + " entry=none";
        return Config.writeUser(Logic.withSetting(Config.user, m, key, value, Config.effective, targets, locator || null));
    }

    // Write one setting of plugin `id` into every configuration entry its
    // instances read, for the plugin manager. A disabled plugin is refused:
    // listing a third-party plugin's row would enable it.
    function setSetting(id, key, value) {
        if (!Registry.has(id)) return "unknown: " + id;
        if (!Registry.isEnabled(id)) return "refused: disabled=" + id;
        return writeSetting(id, key, value, Logic.settingTargets(Config.effective, Registry.manifests[id]));
    }

    // Set, unbind or reset the key of shortcut `shortcut` of plugin `id` in
    // its plugins row, for the plugin manager: a key string rebinds, null
    // unbinds, undefined resets to the manifest's key. The Hyprland layer
    // alone reads the row's keys. A disabled plugin is refused, as for a
    // setting. The reply is one keyed line: `ok` (the save is queued),
    // `unknown: <id>` or a refusal.
    function setKey(id, shortcut, key) {
        if (!Registry.has(id)) return "unknown: " + id;
        if (!Registry.isEnabled(id)) return "refused: disabled=" + id;
        const m = Registry.manifests[id];
        const refusal = Logic.keyRefusal(m, shortcut, key);
        if (refusal !== "") return refusal;
        return Config.writeUser(Logic.withKey(Config.user, m, shortcut, key, Config.effective));
    }

    Component.onCompleted: {
        for (const name of Logic.CAPABILITIES)
            if (!Logic.hasOwn(Capabilities.factories, name))
                console.error("plugins: capability " + name + " has no provider in Capabilities.qml");
    }
}
