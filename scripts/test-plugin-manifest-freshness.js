#!/usr/bin/env node

// Execute the extracted PluginService resync and scan bodies against stub state.
// A manifest path already in knownManifests says the file was read, not what it holds:
// an edited plugin.json keeps its path, so a path-set diff alone never re-judges it.
// An explicit scan must re-read every manifest on disk; a watcher event must not.
// This models the shipped functions; it does not verify Quickshell's FolderListModel.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
// Use the shared comment-aware and string-aware brace reader to prevent truncated extraction.
const { extractBlock, callInScope } = require("./lib/qml-block.js");

const SERVICE = path.join(
    __dirname, "..", "quickshell", "vshell", "Services", "PluginService.qml"
);
const source = fs.readFileSync(SERVICE, "utf8");

const bodies = {
    resyncAll: extractBlock(source, "function resyncAll()"),
    scanPlugins: extractBlock(source, "function scanPlugins()"),
    // The per-path retract and the per-id settle, both shared with the read paths
    // below. Bound here as shipped so the sweep is tested through the same functions.
    retractManifest: extractBlock(source, "function _retractManifest(absPath)"),
    settleReleasedIds: extractBlock(source, "function _settleReleasedIds(pluginIds)")
};

const USER_DIR = "/home/u/.config/vshell/plugins";
const BUNDLED_DIR = "/opt/vgs/config/vshell/plugins";
const SYSTEM_DIR = "/etc/xdg/quickshell/vshell/plugins";

const USER = USER_DIR + "/mine/plugin.json";
const BUNDLED = BUNDLED_DIR + "/vgsMenu/plugin.json";
const SYSTEM = SYSTEM_DIR + "/shipped/plugin.json";

// Every manifest path the stub watchers report, in the order resyncAll considers them.
const ON_DISK = [
    { path: SYSTEM, source: "system" },
    { path: BUNDLED, source: "bundled" },
    { path: USER, source: "user" }
];

// A service whose watchers report `entries` and whose knownManifests already holds `known`.
function service(entries, known) {
    const root = {
        reads: [],
        promoted: [],
        unregistered: [],
        _rereadKnownManifests: false,
        knownManifests: {},
        pathToPluginId: {},
        availablePlugins: {},
        _bundledPluginIds: {},
        pluginDirectory: USER_DIR,
        bundledPluginDirectory: BUNDLED_DIR,
        systemPluginDirectory: SYSTEM_DIR,
        // resyncAll reads the three watchers through snapshotModel; the stub returns
        // the slice of `entries` belonging to each source, the way the shipped one does.
        snapshotModel: (model, sourceTag) => entries.filter(e => e.source === sourceTag),
        loadPluginManifestFile: (p, sourceTag) => root.reads.push(p),
        unregisterPluginByPath: (p, pid) => root.unregistered.push(p),
        _refreshBundledId: () => {},
        promoteShadowedPlugin: pid => root.promoted.push(pid),
        _reportIdLeftEmpty: () => {},
        _updateAvailablePluginsList: () => {},
        pluginListUpdated: () => {},
        checkPluginDirectoryExists: () => {}
    };
    for (const p of known || []) {
        root.knownManifests[p] = { source: "user" };
        root.pathToPluginId[p] = "mine";
    }

    // Every write, not the last one: the blank write is the whole rearm mechanism,
    // because assigning a FolderListModel the URL it already holds re-enumerates nothing.
    const watcher = () => {
        const writes = [];
        return {
            writes,
            set folder(v) { writes.push(v); },
            get folder() { return writes.length ? writes[writes.length - 1] : undefined; }
        };
    };
    const scope = {
        Paths: { toFileUrl: p => "file://" + p },
        userWatcher: watcher(),
        bundledWatcher: watcher(),
        systemWatcher: watcher(),
        resyncDebounce: { restarts: 0, restart() { this.restarts++; } }
    };

    root.stubs = scope;
    root._settleReleasedIds = ids => callInScope(bodies.settleReleasedIds, root, scope, ["pluginIds"], [ids]);
    root._retractManifest = absPath => callInScope(bodies.retractManifest, root, scope, ["absPath"], [absPath]);
    // Return the manifest paths this resync actually read from disk.
    root.resync = () => {
        root.reads.length = 0;
        callInScope(bodies.resyncAll, root, scope);
        return root.reads.slice();
    };
    root.scan = () => callInScope(bodies.scanPlugins, root, scope);
    return root;
}

const EVERY_PATH = ON_DISK.map(e => e.path);

test("a resync reads the manifests at paths it has not seen", () => {
    assert.deepEqual(service(ON_DISK, []).resync(), EVERY_PATH,
        "a first resync must read every manifest on disk");
});

test("a watcher-driven resync of an unchanged path set reads no manifest", () => {
    // This is what makes a directory event cheap, and it is exactly why an edit
    // needs the explicit scan below: the path set does not change when a file does.
    assert.deepEqual(service(ON_DISK, EVERY_PATH).resync(), [],
        "a resync with no scan request must read nothing");
});

test("a scan re-reads every manifest on disk, including paths already known", () => {
    // Without this, adding "overrides" to an installed plugin.json is invisible for
    // the life of the process: the package stays blocked and no number of scans frees it.
    const svc = service(ON_DISK, EVERY_PATH);
    svc.scan();
    assert.deepEqual(svc.resync(), EVERY_PATH,
        "the resync following a scan must re-read every known manifest");
});

test("the scan request is consumed by one resync", () => {
    const svc = service(ON_DISK, EVERY_PATH);
    svc.scan();
    svc.resync();
    assert.equal(svc._rereadKnownManifests, false, "resyncAll must clear the request it consumed");
    assert.deepEqual(svc.resync(), [],
        "a later watcher-driven resync must go back to reading nothing");
});

test("scanPlugins rearms the watchers and schedules the resync that consumes its request", () => {
    // A request nothing consumes would make the NEXT unrelated directory event
    // pay for a full re-read, and would leave the scan the user asked for undone.
    const svc = service(ON_DISK, EVERY_PATH);
    svc.scan();
    assert.equal(svc._rereadKnownManifests, true, "scanPlugins must raise the re-read request");
    assert.equal(svc.stubs.resyncDebounce.restarts, 1, "scanPlugins must schedule a resync");
    for (const [name, dir] of [
        ["userWatcher", USER_DIR],
        ["bundledWatcher", BUNDLED_DIR],
        ["systemWatcher", SYSTEM_DIR]
    ]) {
        // Blank then the URL. Dropping the blank write leaves the model holding the
        // URL it already had, which re-enumerates nothing, and the Scan button
        // silently stops finding a plugin root directory that did not exist at startup.
        assert.deepEqual(svc.stubs[name].writes, ["", "file://" + dir],
            `${name} must be blanked and then pointed back at ${dir}`);
    }
});

test("a manifest gone from disk is unregistered by a scan rather than re-read", () => {
    const remaining = ON_DISK.filter(e => e.path !== USER);
    const svc = service(remaining, EVERY_PATH);
    svc.scan();
    const read = svc.resync();
    assert.deepEqual(read, remaining.map(e => e.path),
        "a re-read pass must read only the manifests still on disk");
    assert.deepEqual(svc.unregistered, [USER], "the removed manifest must be unregistered");
    assert.equal(USER in svc.knownManifests, false, "the removed manifest must leave knownManifests");
    assert.deepEqual(svc.promoted, ["mine"], "the vacated id must be offered to its other claimants");
});

// The second half of a re-read: what _onManifestParsed does with a manifest whose
// contents changed since the path was registered. The shipped bodies run against
// stub collaborators; the functions under test are not stubbed.
const parsed = {
    onManifestParsed: extractBlock(source, "function _onManifestParsed(absPath, manifest, sourceTag, mtimeEpochMs)"),
    releaseRenamedPath: extractBlock(source, "function _releaseRenamedPath(absPath, incomingId)"),
    retractManifest: extractBlock(source, "function _retractManifest(absPath)"),
    releaseManifestPath: extractBlock(source, "function _releaseManifestPath(absPath)"),
    manifestPackageName: extractBlock(source, "function _manifestPackageName(absPath)"),
    reportRereadRefusal: extractBlock(source, "function _reportRereadRefusal(absPath, reason, details)"),
    unregisterPluginByPath: extractBlock(source, "function unregisterPluginByPath(absPath, pluginId)"),
    unloadPlugin: extractBlock(source, "function unloadPlugin(pluginId)"),
    relinkLoadedRecord: extractBlock(source, "function _relinkLoadedRecord(pluginId, info, absPath)"),
    resolveComponentPaths: extractBlock(source, "function _resolveComponentPaths(manifest, dir)"),
    stripDotSlash: extractBlock(source, "function _stripDotSlash(p)"),
    deriveLegacySurface: extractBlock(source, "function _deriveLegacySurface(type, capabilities)"),
    sourcePriority: extractBlock(source, "function _sourcePriority(sourceTag)"),
    setLoadError: extractBlock(source, "function _setLoadError(pluginId, err)"),
    isPluginLoaded: extractBlock(source, "function isPluginLoaded(pluginId)"),
    fvOnLoaded: extractBlock(source, "onLoaded:", source.indexOf("id: manifestFvComp")),
    fvOnLoadFailed: extractBlock(source, "onLoadFailed: err =>", source.indexOf("id: manifestFvComp")),
    settleReleasedIds: extractBlock(source, "function _settleReleasedIds(pluginIds)"),
    clearRefusalError: extractBlock(source, "function _clearRefusalError(absPath)"),
    clearLoadError: extractBlock(source, "function _clearLoadError(pluginId)"),
    refreshBundledId: extractBlock(source, "function _refreshBundledId(pluginId)"),
    hasShippedManifest: extractBlock(source, "function _hasShippedManifest(pluginId)"),
    updateAvailablePluginsList: extractBlock(source, "function _updateAvailablePluginsList()"),
    knownPathsFor: extractBlock(source, "function _knownPathsFor(pluginId)"),
    forceRescanPlugin: extractBlock(source, "function forceRescanPlugin(pluginId)")
};

// The override policy the shipped file already exports to Node for test-bundled-override.js.
const policy = source.match(/\/\/ BEGIN OVERRIDE POLICY\n([\s\S]*?)\/\/ END OVERRIDE POLICY/);
assert.ok(policy, "PluginService.qml must carry the OVERRIDE POLICY markers");

// A manifest the loader accepts, with whatever the case overrides on top.
function manifest(extra) {
    return Object.assign({ id: "mine", name: "Mine", component: "./Widget.qml" }, extra || {});
}

// A service holding one registered, loaded user package at USER, ready to re-read it.
function loader(registered) {
    const root = {
        toasts: [],
        promoted: [],
        gated: [],
        pluginSurfaceKeys: ["widget", "desktop", "daemon", "launcher"],
        knownManifests: {},
        pathToPluginId: {},
        availablePlugins: {},
        loadedPlugins: {},
        pluginLoadErrors: {},
        _bundledPluginIds: {},
        pluginInstances: {},
        pluginWidgetComponents: {},
        pluginDaemonComponents: {},
        pluginLauncherComponents: {},
        pluginDesktopComponents: {},
        _stateWriters: {},
        log: { error: () => {}, warn: () => {} },
        // Leaf effects, none of them the subject of an assertion below.
        _auditBundledRequirement: () => {},
        _reportBundledCollision: () => {},
        _cleanupPluginStateWriter: () => {},
        pluginListUpdated: () => { root.listSignals++; },
        pluginUnloaded: () => {},
        _settlePromotion: () => {},
        _reportedCollisions: {},
        availablePluginsList: [],
        listSignals: 0,
        reads: [],
        runStartupGate: id => root.gated.push(id),
        _gateThenSwap: id => root.gated.push(id),
        _reportIdLeftEmpty: () => {},
        loadPluginManifestFile: (path, sourceTag) => root.reads.push(path),
        // Record the claimed paths as they stand when promotion starts: a path
        // still claiming the id it is abandoning would be re-read by the real
        // promotion and could only expire on the promotion deadline.
        promoteShadowedPlugin: id => root.promoted.push({ id, claimed: Object.keys(root.pathToPluginId) })
    };

    const scope = {
        I18n: { tr: text => ({ arg: value => text.replace("%1", value), toString: () => text }) },
        ToastService: {
            showError: (title, body, command, category) => root.toasts.push({
                title: String(title),
                body: String(body),
                category: String(category)
            })
        },
        SettingsData: { getPluginSetting: (id, key, fallback) => fallback },
        // Quickshell's FileViewError enum, in its shipped order.
        FileViewError: {
            Success: 0,
            Unknown: 1,
            FileNotFound: 2,
            PermissionDenied: 3,
            NotAFile: 4,
            toString: value => ["Success", "Unknown", "FileNotFound", "PermissionDenied", "NotAFile"][value]
        }
    };

    const bind = (name, body, parameters) => {
        root[name] = (...args) => callInScope(body, root, scope, parameters, args);
    };
    bind("_stripDotSlash", parsed.stripDotSlash, ["p"]);
    bind("_deriveLegacySurface", parsed.deriveLegacySurface, ["type", "capabilities"]);
    bind("_resolveComponentPaths", parsed.resolveComponentPaths, ["manifest", "dir"]);
    bind("_sourcePriority", parsed.sourcePriority, ["sourceTag"]);
    bind("_setLoadError", parsed.setLoadError, ["pluginId", "err"]);
    bind("isPluginLoaded", parsed.isPluginLoaded, ["pluginId"]);
    bind("_relinkLoadedRecord", parsed.relinkLoadedRecord, ["pluginId", "info", "absPath"]);
    bind("unloadPlugin", parsed.unloadPlugin, ["pluginId"]);
    bind("unregisterPluginByPath", parsed.unregisterPluginByPath, ["absPath", "pluginId"]);
    bind("_updateAvailablePluginsList", parsed.updateAvailablePluginsList, []);
    bind("_hasShippedManifest", parsed.hasShippedManifest, ["pluginId"]);
    bind("_refreshBundledId", parsed.refreshBundledId, ["pluginId"]);
    bind("_settleReleasedIds", parsed.settleReleasedIds, ["pluginIds"]);
    bind("_manifestPackageName", parsed.manifestPackageName, ["absPath"]);
    bind("_retractManifest", parsed.retractManifest, ["absPath"]);
    bind("_releaseManifestPath", parsed.releaseManifestPath, ["absPath"]);
    bind("_releaseRenamedPath", parsed.releaseRenamedPath, ["absPath", "incomingId"]);
    bind("_clearLoadError", parsed.clearLoadError, ["pluginId"]);
    bind("_clearRefusalError", parsed.clearRefusalError, ["absPath"]);
    bind("_reportRereadRefusal", parsed.reportRereadRefusal, ["absPath", "reason", "details"]);
    bind("_knownPathsFor", parsed.knownPathsFor, ["pluginId"]);
    bind("forceRescanPlugin", parsed.forceRescanPlugin, ["pluginId"]);
    bind("_bundledOverrideDecision", extractBlock(policy[1], "function _bundledOverrideDecision(input)"), ["input"]);
    bind("_declaresBundledOverride", extractBlock(policy[1], "function _declaresBundledOverride(manifest, pluginId)"), ["manifest", "pluginId"]);
    bind("_displacesLoadedPackage", extractBlock(policy[1], "function _displacesLoadedPackage(existing, incomingPath)"), ["existing", "incomingPath"]);
    bind("_onManifestParsed", parsed.onManifestParsed, ["absPath", "manifest", "sourceTag", "mtimeEpochMs"]);

    // The FileView the loader creates per manifest read. Its two handlers are the
    // only place a read that never reached the parser can be reported.
    const view = {
        absPath: USER,
        sourceTag: "user",
        mtimeEpochMs: 1,
        root,
        destroy: () => {},
        text: () => view.raw
    };
    // The FileView's own id, which both handlers use to destroy themselves.
    view.fv = view;
    root.fvLoaded = raw => {
        view.raw = raw;
        callInScope(parsed.fvOnLoaded, view, scope);
    };
    root.fvLoadFailed = err => callInScope(parsed.fvOnLoadFailed, view, scope, ["err"], [err]);
    root.fvLoadFailedAt = (absPath, err) => {
        const other = Object.assign({}, view, { absPath });
        other.fv = other;
        return callInScope(parsed.fvOnLoadFailed, other, scope, ["err"], [err]);
    };

    // A path always claims an id once its manifest has parsed. Owning that id is
    // separate: the block and reclaim branches leave a second path claiming an id
    // whose record lives elsewhere, which is what a blocked duplicate looks like.
    for (const entry of registered) {
        root.pathToPluginId[entry.path] = entry.id;
        root.knownManifests[entry.path] = Object.assign({ source: entry.source }, entry.meta || {});
        if (entry.owner === false)
            continue;
        const record = {
            id: entry.id,
            name: entry.id,
            manifestPath: entry.path,
            source: entry.source,
            loaded: true,
            alwaysAvailable: entry.alwaysAvailable === true,
            overridesBundled: entry.overridesBundled === true
        };
        root.availablePlugins[entry.id] = record;
        root.loadedPlugins[entry.id] = record;
        root.pluginWidgetComponents[entry.id] = { surface: "widget" };
        if (entry.bundledId)
            root._bundledPluginIds[entry.id] = true;
    }
    root._updateAvailablePluginsList();
    root.listSignals = 0;
    return root;
}

test("a re-read whose manifest id changed leaves one id registered for that path", () => {
    // Without the release the renamed package keeps its previous id in
    // availablePlugins with loaded true and its widget still mounted, while no
    // manifest on disk claims it and the removal sweep cannot reach it: that
    // path is still there. Settings lists both ids and the stale one runs on.
    const svc = loader([{ id: "mine", path: USER, source: "user" }]);
    svc._onManifestParsed(USER, manifest({ id: "renamed", name: "Renamed" }), "user", 1);

    assert.equal(svc.pathToPluginId[USER], "renamed", "the path must claim only its new id");
    assert.equal("mine" in svc.availablePlugins, false, "the abandoned id must leave availablePlugins");
    assert.equal("mine" in svc.loadedPlugins, false, "the abandoned id must leave loadedPlugins");
    assert.equal("mine" in svc.pluginWidgetComponents, false, "the abandoned id must give up its widget");
    assert.ok(svc.availablePlugins.renamed, "the new id must be registered");
    assert.equal(svc.availablePlugins.renamed.manifestPath, USER, "the new id must own this path");
});

test("a bundled id vacated by a rename is offered back to its other claimants", () => {
    // The override held the id. Renaming it must not strand the id with a record
    // carrying overridesBundled, which the reclaim path refuses to take back and
    // which hides the disable control for an entry nothing claims.
    const svc = loader([
        { id: "vgsMenu", path: USER, source: "user", bundledId: true, alwaysAvailable: true, overridesBundled: true },
        { id: "vgsMenu", path: BUNDLED, source: "bundled", owner: false }
    ]);

    svc._onManifestParsed(USER, manifest({ id: "renamed", name: "Renamed" }), "user", 1);

    assert.equal("vgsMenu" in svc.availablePlugins, false, "the vacated bundled id must leave availablePlugins");
    assert.deepEqual(svc.promoted.map(p => p.id), ["vgsMenu"], "the vacated bundled id must be offered to its shipped manifest");
    assert.equal(svc.promoted[0].claimed.includes(USER), false,
        "the renamed path must have given up its old id before the promotion reads");
});

test("a rename into a bundled id with no override declaration refreshes the list Settings binds", () => {
    // The block branch returns before the list refresh, so without one in the
    // release the abandoned id stays in availablePluginsList after being unloaded:
    // Settings shows a row whose enable toggle reaches loadPlugin's not-found branch.
    const svc = loader([
        { id: "mine", path: USER, source: "user" },
        { id: "vgsMenu", path: BUNDLED, source: "bundled", bundledId: true, alwaysAvailable: true }
    ]);

    svc._onManifestParsed(USER, manifest({ id: "vgsMenu", name: "VGS Menu" }), "user", 1);

    assert.equal("mine" in svc.availablePlugins, false, "the abandoned id must leave availablePlugins");
    assert.deepEqual(svc.availablePluginsList.map(r => r.id), ["vgsMenu"],
        "the abandoned id must leave the list the settings UI binds");
    assert.ok(svc.listSignals > 0, "the release must announce the change");
});

// One fixture for the states a second claimant produces: the bundled module owns
// the id at its own path while a user package claims the same id from another.
function collision(meta) {
    return loader([
        { id: "vgsMenu", path: BUNDLED, source: "bundled", bundledId: true, alwaysAvailable: true },
        { id: "vgsMenu", path: USER, source: "user", owner: false, meta: meta || { blocked: "bundled" } }
    ]);
}

test("a refused read of a blocked duplicate is reported without blaming the module that owns the id", () => {
    // This is the package the architecture doc tells the user to repair by adding
    // an overrides declaration and scanning. A typo in it must reach the user, and
    // must not record a parse error against the bundled module that is running.
    const svc = collision();
    svc._onManifestParsed(USER, { name: "Mine" }, "user", 1);

    assert.equal(svc.toasts.length, 1, "the blocked duplicate's refusal must reach the user");
    assert.ok(svc.toasts[0].body.includes(USER), "the report must name the refused file");
    assert.match(svc.toasts[0].title, /mine$/, "the title must name the refused package, not the module holding the id");
    assert.equal(svc.toasts[0].category, "plugin-manifest-" + USER, "the category must be the refused path");
    assert.deepEqual(svc.pluginLoadErrors, {}, "no error may be recorded against the owner of the id");
    assert.equal(svc.availablePlugins.vgsMenu.manifestPath, BUNDLED, "the owner record must be untouched");
});

test("renaming a blocked duplicate leaves the running owner alone", () => {
    // Promoting an id that still has a running owner deletes that owner's
    // knownManifests record and re-reads it, tearing down and reloading a plugin
    // because an unrelated shadow copy was renamed.
    const svc = collision();
    svc._onManifestParsed(USER, manifest({ id: "renamed", name: "Renamed" }), "user", 1);

    assert.deepEqual(svc.promoted, [], "an id with a running owner must not be promoted");
    assert.ok(svc.knownManifests[BUNDLED], "the running owner's manifest record must survive");
    assert.equal(svc.availablePlugins.vgsMenu.loaded, true, "the running owner must stay loaded");
});

test("a vacated bundled id with no usable shipped manifest stops being always-available", () => {
    // Left marked, the id keeps hiding the disable control through
    // isAlwaysAvailablePlugin while nothing good on disk claims it.
    const svc = loader([
        { id: "vgsMenu", path: USER, source: "user", bundledId: true, alwaysAvailable: true, overridesBundled: true },
        { id: "vgsMenu", path: BUNDLED, source: "bundled", owner: false, meta: { bad: true } }
    ]);

    svc._onManifestParsed(USER, manifest({ id: "renamed", name: "Renamed" }), "user", 1);

    assert.equal("vgsMenu" in svc._bundledPluginIds, false,
        "an id with no usable shipped manifest must stop being marked always-available");
    assert.deepEqual(svc.promoted.map(p => p.id), ["vgsMenu"], "the vacated id must still be offered to its claimants");
});

test("a refusal on the rescan entry point is reported", () => {
    // forceRescanPlugin drops the availablePlugins record before its reads and
    // never unloads, so a predicate asking who currently owns the id answers no
    // for every refusal a rescan produces while the package is still running.
    const svc = loader([{ id: "mine", path: USER, source: "user" }]);
    assert.equal(svc.forceRescanPlugin("mine"), true, "the rescan must find the manifest");
    assert.deepEqual(svc.reads, [USER], "the rescan must re-read the manifest");

    svc._onManifestParsed(USER, { name: "Mine" }, "user", 1);

    assert.equal(svc.toasts.length, 1, "a refusal during a rescan must reach the user");
    assert.ok(svc.pluginLoadErrors.mine, "the refusal must be recorded against the package being rescanned");
});

test("a manifest that parses answers the refusal recorded for its path", () => {
    // Left standing, the record makes plugin status name a cause that no longer
    // exists, and onPluginLoadFailed returns early for every later component load
    // failure of that plugin, so the only report the user would have had is gone.
    const svc = loader([{ id: "mine", path: USER, source: "user" }]);
    svc._onManifestParsed(USER, { name: "Mine" }, "user", 1);
    assert.ok(svc.pluginLoadErrors.mine, "the refusal must be recorded first");

    svc._onManifestParsed(USER, manifest(), "user", 1);

    assert.deepEqual(svc.pluginLoadErrors, {}, "a manifest that parses must clear the refusal");
    assert.equal(svc.availablePlugins.mine.loaded, true, "the package must still be loaded");
});

test("a load error that is not a refusal survives a manifest that parses", () => {
    // Clearing unconditionally would wipe a live startup-gate error, which is
    // about a package that did compile and load.
    const svc = loader([{ id: "mine", path: USER, source: "user" }]);
    svc._setLoadError("mine", { title: "Startup check failed", details: "" });

    svc._onManifestParsed(USER, manifest(), "user", 1);

    assert.equal(svc.pluginLoadErrors.mine.title, "Startup check failed",
        "a startup-gate error must survive a manifest read");
});

test("a re-read carrying the same id releases nothing", () => {
    const svc = loader([{ id: "mine", path: USER, source: "user" }]);
    svc._onManifestParsed(USER, manifest(), "user", 1);

    assert.equal(svc.pathToPluginId[USER], "mine", "the path must keep its id");
    assert.deepEqual(svc.promoted, [], "an unchanged id must not be offered to another claimant");
    assert.equal(svc.availablePlugins.mine.loaded, true, "the running package must stay loaded");
});

// Each row is one way an edited manifest can be unusable, and what the loader must
// say about it. The package keeps running from the previous read in every case.
// The first two rows run the shipped FileView handlers; the last two run the loader.
const REFUSALS = [
    ["the file no longer parses", svc => svc.fvLoaded("{ not json"), "not valid JSON"],
    // The rendered enum name, not the bare number Quickshell passes the handler.
    ["the file is there but unreadable", svc => svc.fvLoadFailed(3), "PermissionDenied"],
    ["a required field was deleted", svc => svc._onManifestParsed(USER, { name: "Mine" }, "user", 1), "missing its id"],
    ["every component surface was removed", svc => svc._onManifestParsed(USER, manifest({ component: "", components: {} }), "user", 1), "no valid component surface"]
];

test("a re-read the loader cannot use reports the refusal and leaves the package running", () => {
    for (const [why, act, expected] of REFUSALS) {
        const svc = loader([{ id: "mine", path: USER, source: "user" }]);
        act(svc);
        assert.equal(svc.availablePlugins.mine.manifestPath, USER, `${why}: the owner record must survive`);
        assert.equal(svc.availablePlugins.mine.loaded, true, `${why}: the package must keep running`);
        assert.equal(svc.toasts.length, 1, `${why}: the refusal must reach the user`);
        assert.match(svc.toasts[0].body, new RegExp(expected), `${why}: the report must name the cause`);
        // ToastService throttles errors by title, so a title shared by two refusals
        // in one scan shows the user one broken file when two are broken.
        assert.match(svc.toasts[0].title, /mine$/, `${why}: the title must name the refused package`);
        assert.equal(svc.toasts[0].category, "plugin-manifest-" + USER,
            `${why}: the category must be the refused path, so one refusal cannot drop another from the queue`);
        assert.ok(svc.pluginLoadErrors.mine, `${why}: the refusal must be recorded`);
    }
});

test("a manifest found missing is released at the read", () => {
    // The watchers list directories and snapshotModel names a plugin.json inside
    // each one, so a manifest deleted from a surviving directory is marked seen on
    // every resync and the removal sweep never reaches it. Left to that sweep, the
    // package keeps running and keeps its Settings row with nothing on disk behind it.
    const svc = loader([{ id: "mine", path: USER, source: "user" }]);
    svc.fvLoadFailed(2);

    assert.deepEqual(svc.toasts, [], "a missing manifest is a removal, not a refused edit");
    assert.deepEqual(svc.pluginLoadErrors, {}, "a missing manifest must record no load error");
    assert.equal("mine" in svc.availablePlugins, false, "the released id must leave availablePlugins");
    assert.deepEqual(svc.availablePluginsList, [], "the released id must leave the list the settings UI binds");
    assert.equal(USER in svc.knownManifests, false, "the missing manifest must leave knownManifests");
    assert.equal(USER in svc.pathToPluginId, false, "the missing manifest must give up its claim");
});

test("a manifest found missing during a rescan tears the package down", () => {
    // forceRescanPlugin drops the availablePlugins record before its reads and
    // never unloads, so a release that asks only that map finds nothing to tear
    // down. Nothing else reaches the package afterwards: the plugin IPC handler's
    // rescan, reload, list and status all gate on availablePlugins, and the
    // settings row the user could have disabled is gone with the list refresh.
    const svc = loader([{ id: "mine", path: USER, source: "user" }]);
    svc.forceRescanPlugin("mine");
    svc.fvLoadFailed(2);

    assert.equal("mine" in svc.loadedPlugins, false, "the released package must leave loadedPlugins");
    assert.equal("mine" in svc.pluginWidgetComponents, false, "the released package must give up its widget");
    assert.equal(svc.isPluginLoaded("mine"), false, "the released id must not read as loaded");
    assert.equal("mine" in svc.availablePlugins, false, "the released id must leave availablePlugins");
});

test("a read that finds nothing at an unclaimed path releases nothing", () => {
    // A path with no verdict has no id to give up, so running the release for it
    // announces a plugin-list change for a path that claimed nothing.
    const svc = loader([{ id: "mine", path: USER, source: "user" }]);
    svc.fvLoadFailedAt(BUNDLED, 2);

    assert.deepEqual(svc.promoted, [], "an unclaimed path must start no promotion");
    assert.equal(svc.listSignals, 0, "an unclaimed path must announce no change");
    assert.equal(svc.availablePlugins.mine.loaded, true, "an unrelated path must not release a running package");
});

test("a first read of an unregistered path reports no refusal", () => {
    // Nothing is running under that path, so there is no silent failure to report
    // and no user edit to explain. The log line is the whole record.
    const svc = loader([]);
    svc._onManifestParsed(USER, { name: "Mine" }, "user", 1);
    assert.deepEqual(svc.toasts, [], "a failed first read must not toast");
    assert.deepEqual(svc.pluginLoadErrors, {}, "a failed first read must record no load error");
});
