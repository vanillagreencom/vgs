pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// The plugin registry and manager mechanism. Discovers plugin directories,
// validates every manifest through PluginLogic.js, derives the enabled set
// from Config.effective, builds every plugin instance the hosts ask for,
// mounts bar widgets into the active bar's sections, keeps every live
// instance's settings current, and owns enable and disable. Hosts read
// `manifests`, `generation` and the slot API; they never scan the disk,
// build a plugin or assign a plugin property themselves.
Singleton {
    id: root

    // The shipped configuration names the default bar; the core never does.
    readonly property string defaultBarId: Logic.activeBarId(Config.shipped, "")
    readonly property string bundledDir: Quickshell.shellDir + "/plugins"
    readonly property string userDir: Config.userDir + "/plugins"

    // id -> validated manifest, a prototype-free object replaced whole on
    // every scan whose result differs, so bindings re-evaluate once.
    property var manifests: Object.create(null)
    // { dir, error } for every directory whose manifest was refused.
    property var errors: []
    // ids seen in a lower-precedence directory after a higher one claimed them.
    property var collisions: []
    // Why the last scan produced no result, or "" when it did.
    property string scanError: ""
    // Bumped when the manifest set changed. Hosts key their instances on it.
    property int generation: 0
    property bool scanned: false
    property bool rescanPending: false

    // Hosts by kind, registered on completion. summon/hide/toggle route here.
    property var hosts: Object.create(null)

    // Every instance on a surface, keyed by a host-supplied key, for the
    // IPC introspection the smoke reads. A row is { id, kind, origin,
    // instance, capabilities, entry, settingsKey, providers, disposers,
    // screen }: `origin` is "core" for an instance the core built and
    // "plugin" for an item a plugin drew itself and registered through its
    // `builtins` capability; `kind` is the built instance's kind, or the
    // registering instance's kind for a registered item; `entry` is a bar
    // widget's layout entry, `settingsKey` the JSON of the settings the
    // instance holds, `providers` the capability providers made for it, and
    // `disposers` what destroying it releases.
    property var built: Object.create(null)
    property int buildCount: 0

    // Per bar instance, the widgets the core mounted in each of its
    // sections, keyed by the bar's host key: { row, sections: { <section>:
    // { idsKey, entries } } }, `entries` one { key, widget } per wanted
    // layout entry, in order, `widget` null where the build failed, so a
    // later entry keeps its own settings. Not a binding input; read and
    // replaced only by the reconciler.
    property var mounts: Object.create(null)

    function has(id) { return Logic.hasOwn(manifests, id); }

    function rescan() {
        if (scanner.running) { rescanPending = true; return "busy"; }
        scanner.command = [Quickshell.shellDir + "/../bin/vgsh-scan", root.userDir, root.bundledDir];
        scanner.running = true;
        return "ok";
    }

    function applyScan(text) {
        let entries;
        try {
            entries = JSON.parse(text);
        } catch (e) {
            scanError = "scan output does not parse: " + e.message;
            console.error("plugins: " + scanError);
            retry.start();
            return;
        }
        const next = Object.create(null);
        const errs = [];
        const cols = [];
        for (const entry of entries) {
            if (entry.error !== undefined) { errs.push({ dir: entry.dir, error: entry.error }); continue; }
            let raw;
            try {
                raw = JSON.parse(entry.text);
            } catch (e) {
                errs.push({ dir: entry.dir, error: "manifest does not parse: " + e.message });
                continue;
            }
            const r = Logic.validateManifest(raw, entry.dir);
            if (!r.ok) { errs.push({ dir: entry.dir, error: r.error }); continue; }
            if (Logic.hasOwn(next, r.manifest.id)) { cols.push(r.manifest.id + " at " + entry.dir); continue; }
            next[r.manifest.id] = r.manifest;
        }
        for (const e of errs) console.error("plugins: " + e.dir + ": " + e.error);
        const changed = JSON.stringify(next) !== JSON.stringify(root.manifests);
        if (JSON.stringify(cols) !== JSON.stringify(root.collisions))
            for (const c of cols) console.warn("plugins: hidden by a higher-precedence plugin with the same id: " + c);
        root.errors = errs;
        root.collisions = cols;
        root.scanError = "";
        if (changed) { root.manifests = next; root.generation += 1; }
        // `scanned` gates every host key, so it moves last and the hosts
        // see the registry and the generation together.
        root.scanned = true;
        // One line per completed scan, the smoke's readback for a scan that
        // changed nothing and so leaves no other trace.
        console.info("plugins: scan complete changed=" + changed + " generation=" + root.generation);
    }

    Process {
        id: scanner
        stdout: StdioCollector { onStreamFinished: root.applyScan(text) }
        onExited: (code, status) => {
            if (code !== 0) {
                root.scanError = "vgsh-scan exited " + code;
                console.error("plugins: " + root.scanError);
                retry.start();
            }
            if (root.rescanPending) { root.rescanPending = false; root.rescan(); }
        }
    }

    // One retry after a failed scan; a second failure stays visible in scanError.
    Timer {
        id: retry
        interval: 2000
        repeat: false
        onTriggered: if (!root.scanned) root.rescan()
    }

    function isEnabled(id) {
        // Read both inputs on every path so the binding's dependency set is
        // the same whichever branch returns.
        const config = Config.effective;
        const bar = defaultBarId;
        return has(id) && Logic.isEnabled(config, manifests[id], bar);
    }

    readonly property string activeBarId: Logic.activeBarId(Config.effective, defaultBarId)

    // Why plugin `id` is not an enabled plugin, or "": `unknown: <id>` or
    // `refused: disabled=<id>`.
    function enableRefusal(id) {
        if (!has(id)) return "unknown: " + id;
        return isEnabled(id) ? "" : "refused: disabled=" + id;
    }

    // Why plugin `id` cannot be built now, or "": the scan is pending, the
    // configuration is not ready (Config.notReady names why: pending, or
    // the shipped file's failure), the plugin is unknown or
    // disabled, or another plugin holds an exclusive capability it names
    // (from the settled copy of the holders, so a refused plugin builds once
    // the holder lets go). Every input is read on every path so a binding on
    // the result re-evaluates on any of them. slotKey and route consume it.
    function buildRefusal(id) {
        const holders = lendSnapshot;
        const isScanned = scanned;
        const notReady = Config.notReady;
        const enable = enableRefusal(id);
        if (!isScanned) return "refused: scan=pending";
        if (notReady !== "") return "refused: config=" + notReady;
        if (enable !== "") return enable;
        return Logic.lendRefusal(holders, manifests[id]);
    }

    // The key a slot loads plugin `id` under: the id plus the registry
    // generation while buildRefusal is empty, "" otherwise. Every slot and
    // every host reads this one derivation.
    function slotKey(id) {
        return buildRefusal(id) === "" ? id + "@" + generation : "";
    }

    // Who holds each exclusive capability, copied once the change that moved
    // it settled. slotKey reads the copy: a build acquires holds, and a key
    // that read the live record would change inside its own evaluation. A
    // build the stale copy lets through is refused by createInstance, and
    // the next copy takes its key away. A change also lets a refused bar
    // widget build, through reconcile.
    property var lendSnapshot: ({})
    readonly property string exclusiveKey: JSON.stringify(Capabilities.exclusiveHolders())
    onExclusiveKeyChanged: Qt.callLater(refreshLending)

    function refreshLending() {
        const now = Capabilities.exclusiveHolders();
        if (JSON.stringify(now) === JSON.stringify(lendSnapshot)) return;
        lendSnapshot = now;
        reconcile();
    }

    // A configuration change reaches every live instance through one
    // reconcile. A registry change rebuilds the slots keyed on the
    // generation, and a bar rebuilt that way mounts its widgets afresh.
    Connections {
        target: Config
        function onEffectiveChanged() { root.reconcile(); }
    }

    function hiddenByDisabling(id) {
        return Logic.hiddenByDisabling(manifests, Config.effective, id, defaultBarId);
    }

    // Ids of enabled plugins declaring `kind`, sorted.
    function enabledOfKind(kind) {
        return Object.keys(manifests).filter(id => manifests[id].kinds.indexOf(kind) !== -1 && isEnabled(id)).sort();
    }

    // file:// URL of one entry point, or "" when the plugin or kind is absent.
    function entryUrl(id, kind) {
        if (!has(id)) return "";
        const entry = manifests[id].entryPoints[kind];
        if (entry === undefined) return "";
        return "file://" + manifests[id].__sourceDir + "/" + entry;
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
    // turns nested lists into non-Array sequences. Returns null after
    // logging when the plugin cannot be built.
    function createInstance(id, kind, parent, hostKey, layoutEntry, context, screen, locator) {
        const enable = enableRefusal(id);
        if (enable !== "") { console.error("plugins: " + enable); return null; }
        const url = entryUrl(id, kind);
        if (url === "") { console.error("plugins: " + id + " declares no " + kind + " entry point"); return null; }
        const manifest = manifests[id];
        const lent = Logic.lendRefusal(Capabilities.exclusiveHolders(), manifest);
        if (lent !== "") { console.error("plugins: " + id + " " + lent); return null; }
        const component = Qt.createComponent(url);
        if (component.status !== Component.Ready) { console.error("plugins: " + id + " failed to load: " + component.errorString()); return null; }
        const instance = component.createObject(parent);
        if (instance === null) { console.error("plugins: " + id + " created no object"); return null; }
        const settings = Logic.settingsFor(Config.effective, manifest, Logic.settingTargetOf(kind), layoutEntry);
        const onScreen = screen !== undefined && screen !== null ? screen : null;
        const row = { id: id, kind: kind, origin: "core", instance: instance, capabilities: manifest.capabilities, entry: layoutEntry, settingsKey: JSON.stringify(settings), providers: {}, disposers: [], screen: onScreen };
        try {
            row.providers = Capabilities.providersFor({ id: id, manifest: manifest, kind: kind, hostKey: hostKey, screen: onScreen, locator: locator || null, onDispose: fn => row.disposers.push(fn) });
        } catch (e) {
            console.error("plugins: " + id + " capabilities failed: " + e.message);
            for (let i = row.disposers.length - 1; i >= 0; i--) row.disposers[i]();
            instance.destroy();
            return null;
        }
        try {
            instance.shell = facadeFor(manifest, settings, row.providers);
            for (const key of Object.keys(context || {}))
                instance[key] = context[key];
            record(hostKey, row);
            if (kind === "bar") mountBar(hostKey, row);
        } catch (e) {
            console.error("plugins: " + id + " " + kind + " not built: " + e.message);
            if (kind === "bar" && Logic.hasOwn(mounts, hostKey) && mounts[hostKey].row === row) unmountBar(hostKey);
            if (Logic.hasOwn(built, hostKey) && built[hostKey].indexOf(row) !== -1) destroyBuilt(hostKey, instance);
            else {
                for (let i = row.disposers.length - 1; i >= 0; i--) row.disposers[i]();
                instance.destroy();
            }
            return null;
        }
        return instance;
    }

    // A bar widget: built like any instance on its bar's screen, then given
    // the three properties BarWidget declares. `locator` is { section, nth }:
    // which layout entry with this id the widget reads, for its configure
    // capability. A widget that does not declare them is destroyed.
    function createWidget(id, parent, barRow, entry, hostKey, locator) {
        const instance = createInstance(id, "bar-widget", parent, hostKey, entry, null, barRow.screen, locator);
        if (instance === null) return null;
        try {
            instance.bar = barRow.instance;
            instance.moduleName = id;
            instance.settings = instance.shell.settings;
        } catch (e) {
            console.error("plugins: " + id + " bar-widget not built: " + e.message);
            destroyBuilt(hostKey, instance);
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
        for (let i = row.disposers.length - 1; i >= 0; i--) {
            try {
                row.disposers[i]();
            } catch (e) {
                console.error("plugins: " + row.id + " disposer failed: " + e.message);
            }
        }
        row.disposers = [];
        forget(hostKey, instance);
        instance.destroy();
    }

    function record(hostKey, row) {
        const next = Object.assign(Object.create(null), built);
        next[hostKey] = (next[hostKey] || []).concat([row]);
        built = next;
        if (row.origin === "core") buildCount += 1;
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
        record(ctx.hostKey, { id: id, kind: ctx.kind, origin: "plugin", instance: item, capabilities: [], entry: null, settingsKey: "", providers: {}, disposers: [], screen: ctx.screen });
        let live = true;
        const dispose = () => {
            if (!live) return;
            live = false;
            root.forget(ctx.hostKey, item);
        };
        ctx.onDispose(dispose);
        return dispose;
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
        reconcileBar(hostKey, Logic.effectiveLayout(Config.effective, manifests, defaultBarId));
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
                    entries.push({ key: entryKeys[i], widget: widget });
                }
                state.entries = entries;
                state.idsKey = idsKey;
                continue;
            }
            for (let i = 0; i < state.entries.length; i++) {
                const entry = state.entries[i];
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
        const manifest = manifests[row.id];
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
        const layout = Logic.effectiveLayout(Config.effective, manifests, defaultBarId);
        for (const hostKey of Object.keys(mounts)) {
            try {
                reconcileBar(hostKey, layout);
            } catch (e) {
                console.error("plugins: reconciling " + hostKey + " failed: " + e.message);
            }
        }
        for (const hostKey of Object.keys(built)) {
            for (const row of built[hostKey]) {
                if (row.kind === "bar-widget" || row.origin === "plugin" || !has(row.id)) continue;
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
            out[key] = built[key].map(row => ({ id: row.id, kind: row.kind, origin: row.origin, capabilities: row.capabilities }));
        return JSON.stringify(out);
    }

    // One property of one built instance as JSON, for validation rows that
    // read what a plugin actually received. `absent` when no such instance
    // exists; `undefined` when the instance has no such property.
    function readInstance(hostKey, id, property) {
        if (!Logic.hasOwn(built, hostKey)) return "absent";
        const row = built[hostKey].filter(r => r.id === id)[0];
        if (row === undefined) return "absent";
        const value = row.instance[property];
        const json = JSON.stringify(value);
        return json === undefined ? "undefined" : json;
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
        if (!has(id)) return "unknown: " + id;
        if (manifests[id].kinds.indexOf(kind) === -1) return "refused: kind=" + kind + " id=" + id;
        if (verb === "hide") return hosts[kind].hide(id);
        const refusal = buildRefusal(id);
        if (refusal !== "") return refusal;
        return hosts[kind][verb](id, payloadJson, origin || null);
    }

    // The settings an instance of `kind` of plugin `id` receives from its
    // plugins[] row, for a host that reads a plugin's settings for itself.
    function settingsOf(id, kind) {
        return has(id) ? Logic.settingsFor(Config.effective, manifests[id], Logic.settingTargetOf(kind), null) : {};
    }

    // Call one function of one built instance with one text argument and
    // answer its result as text, for validation rows that drive what a
    // user would click. `absent` when no such instance exists; `no-function`
    // when it has no such function.
    function invokeInstance(hostKey, id, name, arg) {
        if (!Logic.hasOwn(built, hostKey)) return "absent";
        const row = built[hostKey].filter(r => r.id === id)[0];
        if (row === undefined) return "absent";
        if (typeof row.instance[name] !== "function") return "no-function";
        const result = row.instance[name](arg);
        return result === undefined ? "" : String(result);
    }

    // Enable or disable one plugin. The reply is one keyed line the CLI
    // prints as is: `ok`, `ok hidden=<a,b>` when disabling the active bar
    // takes those widgets off the screen, `unknown: <id>`, or a refusal
    // naming why the user file was not written.
    function setEnabled(id, enabled) {
        if (!has(id)) return "unknown: " + id;
        const m = manifests[id];
        const hidden = enabled ? [] : hiddenByDisabling(id);
        const written = Config.writeUser(Logic.withEnabled(Config.user, m, enabled, Config.effective));
        if (written !== "ok") return written;
        return hidden.length > 0 ? "ok hidden=" + hidden.join(",") : "ok";
    }

    // Write one setting of one plugin into each configuration entry in
    // `targets` ("layout", "plugins"); `locator` { section, nth } narrows
    // "layout" to one entry. The value is checked against the manifest's
    // schema first. The reply is one keyed line: `ok` (the save is queued),
    // `unknown: <id>` or a refusal.
    function writeSetting(id, key, value, targets, locator) {
        if (!has(id)) return "unknown: " + id;
        const m = manifests[id];
        const refusal = Logic.settingRefusal(m, key, value);
        if (refusal !== "") return refusal;
        if (targets.length === 0) return "refused: setting=" + key + " entry=none";
        return Config.writeUser(Logic.withSetting(Config.user, m, key, value, Config.effective, targets, locator || null));
    }

    // Every discovered plugin as the plugin manager shows it: listing
    // metadata, whether it is enabled, its settings schema and the settings
    // it currently receives (a bar widget's from its first layout entry).
    readonly property var managerRows: Object.keys(manifests).sort().map(id => {
        const m = manifests[id];
        return {
            id: id,
            name: m.name,
            version: m.version,
            description: m.description,
            kinds: m.kinds,
            enabled: isEnabled(id),
            schema: m.schema,
            settings: Logic.managerSettings(Config.effective, m)
        };
    })

    // Write one setting of plugin `id` into every configuration entry its
    // instances read, for the plugin manager. A disabled plugin is refused:
    // listing a third-party plugin's row would enable it.
    function setSetting(id, key, value) {
        if (!has(id)) return "unknown: " + id;
        if (!isEnabled(id)) return "refused: disabled=" + id;
        return writeSetting(id, key, value, Logic.settingTargets(Config.effective, manifests[id]));
    }

    function listJson() {
        const rows = Object.keys(manifests).sort().map(id => ({
            id: id,
            version: manifests[id].version,
            kinds: manifests[id].kinds,
            enabled: isEnabled(id),
            dir: manifests[id].__sourceDir
        }));
        return JSON.stringify({ plugins: rows, errors: errors, collisions: collisions, scanError: scanError, scanned: scanned, config: { ready: Config.ready, shipped: Config.shippedState, user: Config.userState } });
    }

    Component.onCompleted: {
        for (const name of Logic.CAPABILITIES)
            if (!Logic.hasOwn(Capabilities.factories, name))
                console.error("plugins: capability " + name + " has no provider in Capabilities.qml");
        rescan();
    }
}
