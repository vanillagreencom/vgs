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

    const folders = {};
    const scope = {
        Paths: { toFileUrl: p => "file://" + p },
        userWatcher: { set folder(v) { folders.user = v; }, get folder() { return folders.user; } },
        bundledWatcher: { set folder(v) { folders.bundled = v; }, get folder() { return folders.bundled; } },
        systemWatcher: { set folder(v) { folders.system = v; }, get folder() { return folders.system; } },
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
        assert.equal(svc.stubs[name].folder, "file://" + dir,
            `${name} must be pointed back at ${dir} so a directory created after startup is found`);
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
