pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// The plugin registry and manager mechanism. Discovers plugin directories,
// validates every manifest through PluginLogic.js, derives the enabled set
// from Config.effective, builds every plugin instance the hosts ask for,
// and owns enable and disable. Hosts read `manifests`, `generation` and
// the slot API; they never scan the disk or build a plugin themselves.
Singleton {
    id: root

    // The shipped configuration names the default bar; the core never does.
    readonly property string defaultBarId: Config.shipped.bar && typeof Config.shipped.bar.id === "string" ? Config.shipped.bar.id : ""
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

    // Every instance the core built, keyed by a host-supplied key, for the
    // IPC introspection the smoke reads. Value: [{ id, capabilities }].
    property var built: Object.create(null)
    property int buildCount: 0

    // Capability name -> the object a plugin receives for it. Adding a
    // capability is one row here and one name in PluginLogic.CAPABILITIES.
    readonly property var providers: ({
        compositor: { focusWorkspace: function (id) { Compositor.focusWorkspace(id); } }
    })

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
    readonly property string layoutKey: Logic.layoutKey(Config.effective)

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
        const entry = manifests[id].entryPoints[Logic.ENTRY_KEYS[kind]];
        if (entry === undefined) return "";
        return "file://" + manifests[id].__sourceDir + "/" + entry;
    }

    // REVISIT(D010): a process or engine per plugin would replace this scope.
    // The scoped object a plugin receives as `shell`: its manifest, its
    // settings, the widget catalogue for a bar, and one provider per
    // capability its manifest names. Nothing else on it.
    function facadeFor(manifest, hostKey, layoutEntry) {
        const facade = {
            manifest: manifest,
            settings: Logic.settingsFor(Config.effective, manifest, layoutEntry),
            widgets: {
                manifestFor: function (id) { return root.has(id) ? root.manifests[id] : undefined; },
                create: function (id, parent, bar, entry) { return root.createWidget(id, parent, bar, entry, hostKey); },
                destroy: function (instance) { root.destroyInstance(instance, hostKey); }
            }
        };
        for (const name of manifest.vgs.capabilities)
            facade[name] = providers[name];
        return facade;
    }

    // Build one plugin entry point under `parent` and hand it its own
    // facade. Properties are assigned after creation, never as initial
    // properties, which cross a QVariant conversion that drops functions
    // and turns nested lists into non-Array sequences. Returns null after
    // logging when the plugin cannot be built.
    function createInstance(id, kind, parent, hostKey, layoutEntry) {
        if (!has(id) || !isEnabled(id)) { console.warn("plugins: " + id + " is not an enabled plugin"); return null; }
        const url = entryUrl(id, kind);
        if (url === "") { console.warn("plugins: " + id + " declares no " + kind + " entry point"); return null; }
        const component = Qt.createComponent(url);
        if (component.status !== Component.Ready) { console.error("plugins: " + id + " failed to load: " + component.errorString()); return null; }
        const instance = component.createObject(parent);
        if (instance === null) { console.error("plugins: " + id + " created no object"); return null; }
        const manifest = manifests[id];
        instance.shell = facadeFor(manifest, hostKey, layoutEntry);
        record(hostKey, { id: id, kind: kind, instance: instance, capabilities: manifest.vgs.capabilities });
        return instance;
    }

    // A bar widget: built like any instance, then given the three properties
    // BarWidget declares.
    function createWidget(id, parent, bar, entry, hostKey) {
        const instance = createInstance(id, "bar-widget", parent, hostKey, entry);
        if (instance === null) return null;
        instance.bar = bar;
        instance.moduleName = id;
        instance.settings = Logic.settingsFor(Config.effective, manifests[id], entry);
        return instance;
    }

    function destroyInstance(instance, hostKey) {
        if (instance === null || instance === undefined) return;
        forget(hostKey, instance);
        instance.destroy();
    }

    function record(hostKey, row) {
        const next = Object.assign(Object.create(null), built);
        next[hostKey] = (next[hostKey] || []).concat([row]);
        built = next;
        buildCount += 1;
    }

    function forget(hostKey, instance) {
        if (!Logic.hasOwn(built, hostKey)) return;
        const next = Object.assign(Object.create(null), built);
        next[hostKey] = next[hostKey].filter(row => row.instance !== instance);
        if (next[hostKey].length === 0) delete next[hostKey];
        built = next;
    }

    function builtJson() {
        const out = {};
        for (const key of Object.keys(built))
            out[key] = built[key].map(row => ({ id: row.id, kind: row.kind, capabilities: row.capabilities }));
        return JSON.stringify(out);
    }

    // Kind-generic summon, hide and toggle. A host registers itself under
    // its kind on completion; a kind with no host answers so.
    function registerHost(kind, host) {
        const next = Object.assign(Object.create(null), hosts);
        next[kind] = host;
        hosts = next;
    }

    function route(verb, kind, id, payloadJson) {
        if (!Logic.hasOwn(hosts, kind)) return "refused: no-host=" + kind;
        if (!has(id)) return "unknown: " + id;
        if (manifests[id].kinds.indexOf(kind) === -1) return "refused: kind=" + kind + " id=" + id;
        return hosts[kind][verb](id, payloadJson);
    }

    // Enable or disable one plugin. The reply is one keyed line the CLI
    // prints as is: `ok`, `ok hidden=<a,b>` when disabling the active bar
    // takes those widgets off the screen, `unknown: <id>`, or a refusal
    // naming why the user file was not written.
    function setEnabled(id, enabled) {
        if (!has(id)) return "unknown: " + id;
        if (Config.userParseFailed) return "refused: user-config=unparseable path=" + Config.userPath;
        const m = manifests[id];
        const hidden = enabled ? [] : hiddenByDisabling(id);
        const written = Config.writeUser(Logic.withEnabled(Config.user, m, enabled, Config.effective));
        if (written !== "ok") return written;
        return hidden.length > 0 ? "ok hidden=" + hidden.join(",") : "ok";
    }

    function listJson() {
        const rows = Object.keys(manifests).sort().map(id => ({
            id: id,
            version: manifests[id].version,
            kinds: manifests[id].kinds,
            enabled: isEnabled(id),
            dir: manifests[id].__sourceDir
        }));
        return JSON.stringify({ plugins: rows, errors: errors, collisions: collisions, scanError: scanError, scanned: scanned });
    }

    Component.onCompleted: rescan()
}
