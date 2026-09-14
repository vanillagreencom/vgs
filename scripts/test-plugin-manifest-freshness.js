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
    scanPlugins: extractBlock(source, "function scanPlugins()")
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
    fvOnLoadFailed: extractBlock(source, "onLoadFailed: err =>", source.indexOf("id: manifestFvComp"))
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
        _updateAvailablePluginsList: () => {},
        pluginListUpdated: () => {},
        pluginUnloaded: () => {},
        _settlePromotion: () => {},
        runStartupGate: id => root.gated.push(id),
        _gateThenSwap: id => root.gated.push(id),
        _refreshBundledId: () => {},
        _reportIdLeftEmpty: () => {},
        promoteShadowedPlugin: id => root.promoted.push(id)
    };

    const scope = {
        I18n: { tr: text => ({ arg: value => text.replace("%1", value), toString: () => text }) },
        ToastService: { showError: (title, body) => root.toasts.push({ title: String(title), body: String(body) }) },
        SettingsData: { getPluginSetting: (id, key, fallback) => fallback }
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
    bind("_releaseRenamedPath", parsed.releaseRenamedPath, ["absPath", "incomingId"]);
    bind("_reportRereadRefusal", parsed.reportRereadRefusal, ["absPath", "reason", "details"]);
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

    for (const entry of registered) {
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
        root.pathToPluginId[entry.path] = entry.id;
        root.knownManifests[entry.path] = { source: entry.source };
        root.pluginWidgetComponents[entry.id] = { surface: "widget" };
        if (entry.bundledId)
            root._bundledPluginIds[entry.id] = true;
    }
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
        { id: "vgsMenu", path: USER, source: "user", bundledId: true, alwaysAvailable: true, overridesBundled: true }
    ]);
    svc.knownManifests[BUNDLED] = { source: "bundled" };
    svc.pathToPluginId[BUNDLED] = "vgsMenu";

    svc._onManifestParsed(USER, manifest({ id: "renamed", name: "Renamed" }), "user", 1);

    assert.equal("vgsMenu" in svc.availablePlugins, false, "the vacated bundled id must leave availablePlugins");
    assert.deepEqual(svc.promoted, ["vgsMenu"], "the vacated bundled id must be offered to its shipped manifest");
});

test("a re-read carrying the same id releases nothing", () => {
    const svc = loader([{ id: "mine", path: USER, source: "user" }]);
    svc._onManifestParsed(USER, manifest(), "user", 1);

    assert.equal(svc.pathToPluginId[USER], "mine", "the path must keep its id");
    assert.deepEqual(svc.promoted, [], "an unchanged id must not be offered to another claimant");
    assert.equal(svc.availablePlugins.mine.loaded, true, "the running package must stay loaded");
});

// Each row is one way an edited manifest can be unusable, and the reason the loader
// reports for it. The package keeps running from the previous read in every case.
// The first two rows run the shipped FileView handlers; the last two run the loader.
const REFUSALS = [
    ["the file no longer parses", svc => svc.fvLoaded("{ not json"), "not valid JSON"],
    ["the file could not be opened", svc => svc.fvLoadFailed("FileNotFound"), "could not be opened"],
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
        assert.ok(svc.pluginLoadErrors.mine, `${why}: the refusal must be recorded for the IPC reader`);
    }
});

test("a first read of an unregistered path reports no refusal", () => {
    // Nothing is running under that path, so there is no silent failure to report
    // and no user edit to explain. The log line is the whole record.
    const svc = loader([]);
    svc._onManifestParsed(USER, { name: "Mine" }, "user", 1);
    assert.deepEqual(svc.toasts, [], "a failed first read must not toast");
    assert.deepEqual(svc.pluginLoadErrors, {}, "a failed first read must record no load error");
});
