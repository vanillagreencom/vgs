pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// The plugin registry and manager mechanism. Discovers plugin directories,
// validates every manifest through PluginLogic.js, derives the enabled set
// from Config.effective, and owns enable and disable. Hosts read `manifests`,
// `generation` and `entryUrl()`; they never scan the disk themselves.
Singleton {
    id: root

    // The shipped configuration names the default bar; the core never does.
    readonly property string defaultBarId: Config.shipped.bar && typeof Config.shipped.bar.id === "string" ? Config.shipped.bar.id : ""
    readonly property string bundledDir: Quickshell.shellDir + "/plugins"
    readonly property string userDir: Config.userDir + "/plugins"

    // id -> validated manifest. Replaced whole on every scan so bindings
    // re-evaluate once.
    property var manifests: ({})
    // { dir, error } for every directory whose manifest was refused.
    property var errors: []
    // ids seen in a lower-precedence directory after a higher one claimed them.
    property var collisions: []
    // Bumped when plugin code should be reloaded. Hosts key their instances on it.
    property int generation: 0
    property bool scanned: false

    function rescan() {
        if (scanner.running) return;
        scanner.command = [Quickshell.shellDir + "/../bin/vgsh-scan", root.userDir, root.bundledDir];
        scanner.running = true;
    }

    function applyScan(text) {
        let entries;
        try {
            entries = JSON.parse(text);
        } catch (e) {
            console.error("plugins: scan output does not parse: " + e.message);
            return;
        }
        const next = {};
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
            if (next[r.manifest.id] !== undefined) { cols.push(r.manifest.id + " at " + entry.dir); continue; }
            next[r.manifest.id] = r.manifest;
        }
        for (const e of errs) console.error("plugins: " + e.dir + ": " + e.error);
        for (const c of cols) console.warn("plugins: hidden by a higher-precedence plugin with the same id: " + c);
        root.manifests = next;
        root.errors = errs;
        root.collisions = cols;
        root.scanned = true;
        root.generation += 1;
    }

    Process {
        id: scanner
        stdout: StdioCollector { onStreamFinished: root.applyScan(text) }
        onExited: (code, status) => { if (code !== 0) console.error("plugins: vgsh-scan exited " + code); }
    }

    function isEnabled(id) {
        const m = manifests[id];
        return m !== undefined && Logic.isEnabled(Config.effective, m, defaultBarId);
    }

    readonly property string activeBarId: Logic.activeBarId(Config.effective, defaultBarId)

    function hiddenByDisabling(id) {
        return Logic.hiddenByDisabling(manifests, Config.effective, id, defaultBarId);
    }

    // file:// URL of one entry point, or "" when the plugin or kind is absent.
    function entryUrl(id, kind) {
        const m = manifests[id];
        if (m === undefined) return "";
        const entry = m.entryPoints[Logic.ENTRY_KEYS[kind]];
        if (entry === undefined) return "";
        return "file://" + m.__sourceDir + "/" + entry;
    }

    // The scoped object a plugin receives as `shell`. It carries only what
    // the manifest declares: every plugin gets its manifest and the widget
    // catalogue; `compositor` exists only for a plugin that names the
    // capability.
    function facadeFor(manifest) {
        const facade = {
            manifest: manifest,
            widgets: {
                entryUrl: function (id) { return root.isEnabled(id) ? root.entryUrl(id, "bar-widget") : ""; },
                manifestFor: function (id) { return root.manifests[id]; }
            }
        };
        if (manifest.vgs.capabilities.indexOf("compositor") !== -1)
            facade.compositor = { focusWorkspace: Compositor.focusWorkspace };
        return facade;
    }

    // Enable or disable one plugin. The reply is one keyed line the CLI
    // prints as is: `ok`, `ok hidden=<a,b>` when disabling the active bar
    // takes those widgets off the screen, or `unknown: <id>`.
    function setEnabled(id, enabled) {
        const m = manifests[id];
        if (m === undefined) return "unknown: " + id;
        const hidden = enabled ? [] : hiddenByDisabling(id);
        Config.writeUser(Logic.withEnabled(Config.user, m, enabled, Config.effective));
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
        return JSON.stringify({ plugins: rows, errors: errors, collisions: collisions });
    }

    Component.onCompleted: rescan()
}
