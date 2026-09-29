pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// What is installed and what may be built. Discovers plugin directories
// through bin/vgsh-scan, validates every manifest through PluginLogic.js,
// keeps each plugin's source revision and snapshot URL, and derives from
// Config.effective which plugins are enabled and which may be built now.
// Hosts key their slots on `slotKey`; Plugins builds from `entryUrl` and
// reacts to `changed` and `lendingChanged`. Nothing here builds, destroys
// or writes.
Singleton {
    id: root

    // The shipped configuration names the default bar; the core never does.
    readonly property string defaultBarId: Logic.activeBarId(Config.shipped, "")
    readonly property string bundledDir: Quickshell.shellDir + "/plugins"
    readonly property string userDir: Config.userDir + "/plugins"
    // Where the scanner publishes each plugin's source revision for this
    // shell process; the runner removes the roots of earlier shells.
    readonly property string sourceDir: Quickshell.env("XDG_RUNTIME_DIR") + "/vgsh-sources-" + Quickshell.processId
    readonly property string coreRequirementsFile: Quickshell.shellDir + "/../config/requirements.json"

    // id -> validated manifest, a prototype-free object replaced whole on
    // every scan whose result differs, so bindings re-evaluate once. Each
    // carries `__revision` and `__loadUrl` from the scan.
    property var manifests: Object.create(null)
    // id -> the commands of its `requirements` the last scan did not find
    // on PATH, for every plugin in `manifests`; replaced whole when a scan
    // finds a different set, apart from the manifests, so a command
    // installed or removed rebuilds nothing.
    property var missingCommands: Object.create(null)
    // The core's own requirements, config/requirements.json as
    // PluginLogic.normalRequirements returns it, and the commands of it the
    // last scan did not find on PATH; each replaced only when a scan reads
    // a different one. An unreadable or refused file leaves both empty and
    // is one of `errors`.
    property var coreRequirements: []
    property var coreMissing: []
    // Whose requirements a notice can list, by owner id: every plugin's
    // manifest and the core's owner, PluginLogic.coreOwner; and each
    // owner's missing commands.
    readonly property var requirementOwners: Object.assign(Object.create(null), manifests, { [Logic.CORE_OWNER]: Logic.coreOwner(coreRequirements) })
    readonly property var ownerMissing: Object.assign(Object.create(null), missingCommands, { [Logic.CORE_OWNER]: coreMissing })
    // { dir, error } for every directory whose manifest was refused.
    property var errors: []
    // ids seen in a lower-precedence directory after a higher one claimed them.
    property var collisions: []
    // Why the last scan produced no result, or "" when it did.
    property string scanError: ""
    // { id, dir, error } for every problem the Hyprland layer reports: a
    // bind a conflict skipped, a `keys` name no bind declares (each with the
    // plugin's id) and a failed step (id ""). HyprlandLayer.qml hands them
    // over; listJson and managerRows read them here.
    property var hyprlandProblems: []
    property bool scanned: false
    property bool rescanPending: false
    property var completion: null

    // The manifest map was replaced: a plugin appeared, went, or changed
    // its source revision.
    signal changed()
    // The settled copy of the exclusive holders moved.
    signal lendingChanged()
    // A scan attempt ended, with a result or with scanError; the first runs
    // at start. The guarded shell follows the applied theme package on it.
    signal scanFinished()

    function has(id) { return Logic.hasOwn(manifests, id); }

    // Start one scan; a scan asked for while one runs starts when it ends.
    // The scan keeps the revisions of every listed plugin and every live
    // instance, which the build records know, and prunes the rest.
    function rescan() {
        if (scanner.running) { rescanPending = true; return "busy"; }
        const command = [Quickshell.shellDir + "/../bin/vgsh-scan", "--core", coreRequirementsFile, "--snapshot-dir", sourceDir];
        const keep = Object.create(null);
        for (const id of Object.keys(manifests)) keep[manifests[id].__revision] = true;
        for (const revision of Plugins.liveRevisions()) keep[revision] = true;
        for (const revision of Object.keys(keep)) command.push("--retain", revision);
        scanner.command = command.concat([root.userDir, root.bundledDir]);
        completion = null;
        scanner.running = true;
        return "ok";
    }

    // The scan's core element: { requirements, error }, the list judged as a
    // manifest's `requirements` is and normalized, or the reason it is not.
    function readCore(entry) {
        let list;
        try {
            list = JSON.parse(entry.text);
        } catch (e) {
            return { requirements: [], error: "core requirements do not parse: " + e.message };
        }
        const error = Logic.requirementsError(list);
        if (error !== "") return { requirements: [], error: "core requirements: " + error };
        if (!Array.isArray(entry.missing)) return { requirements: [], error: "core requirements carry no missing list" };
        return { requirements: Logic.normalRequirements(list), error: "" };
    }

    function applyScan(text) {
        let entries;
        try {
            entries = JSON.parse(text);
            if (!Array.isArray(entries)) throw new Error("expected an entry list");
        } catch (e) {
            scanError = "scan output does not parse: " + e.message;
            return;
        }
        const next = Object.create(null);
        const nextMissing = Object.create(null);
        const errs = [];
        const cols = [];
        let nextCore = [];
        let nextCoreMissing = [];
        for (const entry of entries) {
            if (entry.error !== undefined) { errs.push({ dir: entry.dir, error: entry.error }); continue; }
            if (entry.core !== undefined) {
                const core = readCore(entry);
                if (core.error !== "") { errs.push({ dir: entry.core, error: core.error }); continue; }
                nextCore = core.requirements;
                nextCoreMissing = entry.missing;
                continue;
            }
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
            if (!Array.isArray(entry.missing)) {
                scanError = "scan output does not parse: " + entry.dir + " carries no missing list";
                return;
            }
            r.manifest.__revision = entry.revision;
            r.manifest.__loadUrl = entry.loadUrl;
            next[r.manifest.id] = r.manifest;
            nextMissing[r.manifest.id] = entry.missing;
        }
        for (const e of errs) console.error("plugins: " + e.dir + ": " + e.error);
        const isChanged = JSON.stringify(next) !== JSON.stringify(root.manifests);
        if (JSON.stringify(cols) !== JSON.stringify(root.collisions))
            for (const c of cols) console.warn("plugins: hidden by a higher-precedence plugin with the same id: " + c);
        root.errors = errs;
        root.collisions = cols;
        root.scanError = "";
        // Before the map, so no row reads a new plugin's requirements against
        // the last scan's probe.
        if (JSON.stringify(nextMissing) !== JSON.stringify(root.missingCommands)) root.missingCommands = nextMissing;
        if (JSON.stringify(nextCore) !== JSON.stringify(root.coreRequirements)) root.coreRequirements = nextCore;
        if (JSON.stringify(nextCoreMissing) !== JSON.stringify(root.coreMissing)) root.coreMissing = nextCoreMissing;
        if (isChanged) root.manifests = next;
        // `scanned` gates every slot key, so it moves after the map.
        root.scanned = true;
        if (isChanged) changed();
        // One line per completed scan, the smoke's readback for a scan that
        // changed nothing and so leaves no other trace.
        console.info("plugins: scan complete changed=" + isChanged);
    }

    Process {
        id: scanner
        stdout: StdioCollector { id: output }
        onExited: (code, status) => { root.completion = { code: code, status: status }; }
        onRunningChanged: {
            if (running) return;
            if (root.completion === null)
                root.scanError = "vgsh-scan did not start";
            else if (root.completion.code !== 0 || root.completion.status !== 0)
                root.scanError = "vgsh-scan exited " + root.completion.code + " status=" + root.completion.status;
            else root.applyScan(output.text);
            if (root.scanError !== "") console.error("plugins: " + root.scanError);
            root.scanFinished();
            if (root.rescanPending) {
                root.rescanPending = false;
                root.rescan();
            }
        }
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
    // the shipped file's failure), the plugin is unknown or disabled, or
    // another plugin holds an exclusive capability it names (from the
    // settled copy of the holders, so a refused plugin builds once the
    // holder lets go). Every input is read on every path so a binding on
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

    // The key a slot loads plugin `id` under: its id and source revision
    // while buildRefusal is empty, "" otherwise. Every slot and every host
    // reads this one derivation.
    function slotKey(id) {
        return buildRefusal(id) === "" ? id + "@" + manifests[id].__revision : "";
    }

    // Who holds each exclusive capability, copied once the change that moved
    // it settled. slotKey reads the copy: a build acquires holds, and a key
    // that read the live record would change inside its own evaluation. A
    // build the stale copy lets through is refused at build time, and the
    // next copy takes its key away.
    property var lendSnapshot: ({})
    readonly property string exclusiveKey: JSON.stringify(Capabilities.exclusiveHolders())
    onExclusiveKeyChanged: Qt.callLater(refreshLending)

    function refreshLending() {
        const now = Capabilities.exclusiveHolders();
        if (JSON.stringify(now) === JSON.stringify(lendSnapshot)) return;
        lendSnapshot = now;
        lendingChanged();
    }

    // Ids of enabled plugins declaring `kind`, sorted.
    function enabledOfKind(kind) {
        return Object.keys(manifests).filter(id => manifests[id].kinds.indexOf(kind) !== -1 && isEnabled(id)).sort();
    }

    // file:// URL of one entry point inside the plugin's published
    // snapshot, or "" when the plugin or kind is absent.
    function entryUrl(id, kind) {
        if (!has(id)) return "";
        const entry = manifests[id].entryPoints[kind];
        if (entry === undefined) return "";
        return manifests[id].__loadUrl + "/" + entry.split("/").map(encodeURIComponent).join("/");
    }

    // The settings an instance of `kind` of plugin `id` receives from its
    // plugins[] row, for a host that reads a plugin's settings for itself.
    function settingsOf(id, kind) {
        return has(id) ? Logic.settingsFor(Config.effective, manifests[id], Logic.settingTargetOf(kind), null) : {};
    }

    // The commands the last scan did not find, by owner: the core's and
    // every enabled plugin's, each list a copy. The `doctor` capability's
    // `missing`; a binding on it follows each scan, enable and disable.
    function enabledOwnerMissing() {
        const out = { [Logic.CORE_OWNER]: coreMissing.slice() };
        for (const id of Object.keys(manifests))
            if (isEnabled(id)) out[id] = Logic.hasOwn(missingCommands, id) ? missingCommands[id].slice() : [];
        return out;
    }

    // Plugin `id`'s requirement rows, each with its state from the last
    // scan: PluginLogic.requirementRows.
    function requirementsOf(id) {
        return Logic.requirementRows(manifests[id], Logic.hasOwn(missingCommands, id) ? missingCommands[id] : []);
    }

    // Where a plugin was found: `bundled` under the shell's own plugins
    // directory, `installed` under the user's.
    function sourceOf(manifest) {
        return manifest.__sourceDir.indexOf(bundledDir + "/") === 0 ? "bundled" : "installed";
    }

    // Every discovered plugin as the plugin manager shows it: listing
    // metadata, its icon, capabilities and source, whether it is enabled,
    // its settings schema, the settings it currently receives (a bar
    // widget's from its first layout entry), its Keys rows, its Status rows
    // (PluginLogic.statusRows over the values it published), its
    // requirements with their state and its errors:
    // each failed build of one of its kinds, once per cause, then each
    // problem the Hyprland layer reports for it.
    readonly property var managerRows: {
        const config = Config.effective;
        const descriptions = Capabilities.shortcutDescriptions;
        const failures = Plugins.failedBuilds;
        const problems = hyprlandProblems;
        return Object.keys(manifests).sort().map(id => {
            const m = manifests[id];
            const errors = [];
            for (const key of Object.keys(failures)) {
                const failure = failures[key];
                const text = "build failed: " + failure.kind + ": " + failure.error;
                if (failure.id === id && errors.indexOf(text) === -1) errors.push(text);
            }
            for (const problem of problems)
                if (problem.id === id) errors.push(problem.error);
            return {
                id: id,
                name: m.name,
                version: m.version,
                description: m.description,
                author: m.author,
                license: m.license === undefined ? "" : m.license,
                icon: Logic.pluginIcon(m),
                kinds: m.kinds,
                capabilities: m.capabilities,
                source: sourceOf(m),
                enabled: isEnabled(id),
                schema: m.schema,
                settings: Logic.managerSettings(config, m),
                binds: Logic.bindRows(config, m, descriptions),
                status: Logic.statusRows(m, PluginStatus.valuesOf(id)),
                requirements: requirementsOf(id),
                errors: errors
            };
        });
    }

    function listJson() {
        const rows = Object.keys(manifests).sort().map(id => ({
            id: id,
            version: manifests[id].version,
            kinds: manifests[id].kinds,
            enabled: isEnabled(id),
            dir: manifests[id].__sourceDir,
            revision: manifests[id].__revision,
            requirements: requirementsOf(id)
        }));
        // Before the first scan no id is known, so none is reported unknown.
        const unknown = scanned ? Logic.unknownIds(Config.effective, manifests) : [];
        const extra = hyprlandProblems.map(p => ({ dir: p.dir, error: p.error }));
        return JSON.stringify({ plugins: rows, errors: errors.concat(extra), collisions: collisions, unknown: unknown, scanError: scanError, scanned: scanned, config: { ready: Config.ready, shipped: Config.shippedState, user: Config.userState } });
    }

    Component.onCompleted: rescan()
}
