#!/usr/bin/env node

// Test the extracted bundled-plugin override policy and runtime version comparator.
// An ID collision alone must not enable a user package. An explicit override inherits availability.
// Shipped manifest requirements must accept VERSION because users can copy them into overrides.

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const REPO = path.join(__dirname, "..");
const SERVICE = path.join(
    REPO, "quickshell", "vshell", "Services", "PluginService.qml"
);

const source = fs.readFileSync(SERVICE, "utf8");
const match = source.match(/\/\/ BEGIN OVERRIDE POLICY\n([\s\S]*?)\/\/ END OVERRIDE POLICY/);
assert.ok(match, "PluginService.qml must carry the OVERRIDE POLICY markers");

// The extracted policy uses plain JavaScript functions without QML APIs.
const {
    _bundledOverrideDecision: decide,
    _declaresBundledOverride: declares,
    _displacesLoadedPackage: displaces
} = new Function(
    `${match[1]}\nreturn { _bundledOverrideDecision, _declaresBundledOverride, _displacesLoadedPackage };`
)();

const PRIORITY = {
    user: 30,
    bundled: 20,
    system: 10
};

function owner(sourceTag, extra) {
    return Object.assign({
        source: sourceTag,
        overridesBundled: false,
        loaded: true
    }, extra || {});
}

function verdict(opts) {
    const sourceTag = opts.sourceTag;
    const existing = opts.existing || null;
    return decide({
        sourceTag: sourceTag,
        pluginId: opts.pluginId || "vgsMenu",
        manifest: opts.manifest || {},
        bundledId: opts.bundledId !== false,
        existing: existing,
        isPureDesktop: opts.isPureDesktop === true,
        userEnabled: opts.userEnabled === true,
        incomingPriority: PRIORITY[sourceTag],
        existingPriority: existing ? PRIORITY[existing.source] : -1,
        incomingPath: opts.incomingPath,
        existingPath: existing ? existing.manifestPath : ""
    });
}

test("_declaresBundledOverride reads the id, true, or a list containing the id", () => {
    for (const [manifest, expected, why] of [
        [{ overrides: "vgsMenu" }, true, "the id names the claim"],
        [{ overrides: "somethingElse" }, false, "a claim on another id is not a claim on this one"],
        [{ overrides: true }, true, "`true` claims whatever id the manifest declares"],
        [{ overrides: ["a", "vgsMenu"] }, true, "a list containing the id claims it"],
        [{ overrides: ["a", "b"] }, false, "a list without the id does not"],
        [{}, false, "no marker is no claim"],
        [{ overrides: false }, false, "an explicit false is no claim"]
    ]) {
        assert.equal(declares(manifest, "vgsMenu"), expected, why);
    }
});

test("a bundled manifest with no incumbent owns its id, always available and enabled", () => {
    let v = verdict({ sourceTag: "bundled" });
    assert.equal(v.action, "replace", "a bundled manifest with no incumbent owns its id");
    assert.equal(v.alwaysAvailable, true, "bundled packages are always available");
    assert.equal(v.enabled, true, "and therefore auto-enabled without a user setting");
    assert.equal(v.overridesBundled, false, "a bundled package does not override itself");
});

test("a bare collision with a bundled id is blocked whatever the source, marker or user setting", () => {
    let v;
    v = verdict({ sourceTag: "user", existing: owner("bundled") });
    assert.equal(v.action, "block", "a user package reusing a bundled id without a marker is inert");
    assert.equal(v.enabled, false, "a bare collision is never auto-enabled");
    assert.equal(v.alwaysAvailable, false, "and never inherits always-available");

    v = verdict({ sourceTag: "user", existing: owner("bundled"), userEnabled: true });
    assert.equal(v.action, "block", "even a user-enabled collision does not take a shipped id");

    v = verdict({ sourceTag: "system", existing: owner("bundled") });
    assert.equal(v.action, "block", "the rule is about the id, not the user directory");

    v = verdict({ sourceTag: "user", manifest: { overrides: "other" }, existing: owner("bundled") });
    assert.equal(v.action, "block", "a marker naming a different id does not claim this one");
});

test("a declared override takes the bundled id and inherits availability", () => {
    let v;
    v = verdict({ sourceTag: "user", manifest: { overrides: "vgsMenu" }, existing: owner("bundled") });
    assert.equal(v.action, "replace", "a declared override takes the id");
    assert.equal(v.alwaysAvailable, true, "and inherits always-available");
    assert.equal(v.enabled, true, "so it loads without the user enabling it (the VGS-13 hole)");
    assert.equal(v.overridesBundled, true);
});

test("before the bundled id is known a user manifest is ordinary and a claim grants nothing yet", () => {
    let v;
    // A user manifest can arrive before the bundled ID is known.
    v = verdict({ sourceTag: "user", bundledId: false });
    assert.equal(v.action, "replace", "an unknown id is just an ordinary plugin");
    assert.equal(v.enabled, false, "which stays disabled until the user enables it");
    assert.equal(v.alwaysAvailable, false);

    v = verdict({ sourceTag: "user", manifest: { overrides: "vgsMenu" }, bundledId: false });
    assert.equal(v.overridesBundled, true, "the claim is recorded even before the shipped package is seen");
    assert.equal(v.alwaysAvailable, false, "but grants nothing until there is something to override");
});

test("the bundled manifest reclaims a bare collision and is shadowed by a declared override", () => {
    let v;
    // The bundled manifest must displace a bare collision but retain an explicit override.
    v = verdict({ sourceTag: "bundled", existing: owner("user") });
    assert.equal(v.action, "reclaim", "the shipped package reclaims its id from a bare collision");
    assert.equal(v.alwaysAvailable, true);

    v = verdict({ sourceTag: "bundled", existing: owner("user", { overridesBundled: true }) });
    assert.equal(v.action, "shadow", "a declared override keeps the id whichever order the scan ran in");

    v = verdict({ sourceTag: "bundled", existing: owner("system") });
    assert.equal(v.action, "reclaim", "a system collision is reclaimed the same way");
});

test("ordinary ids follow priority and stay opt-in unless enabled or desktop-only", () => {
    let v;
    v = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, existing: owner("system") });
    assert.equal(v.action, "replace", "user still outranks system for an ordinary id");
    assert.equal(v.enabled, false, "and ordinary plugins stay opt-in");

    v = verdict({ sourceTag: "system", pluginId: "somePlugin", bundledId: false, existing: owner("user") });
    assert.equal(v.action, "shadow", "system does not outrank user");

    v = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, userEnabled: true });
    assert.equal(v.enabled, true, "an enabled ordinary plugin loads");

    v = verdict({ sourceTag: "user", pluginId: "someWidget", bundledId: false, isPureDesktop: true });
    assert.equal(v.enabled, true, "desktop-only packages are enabled by their instances, as before");
});

// Equal-priority manifest reads can finish in either order. Both orders must select the same path.
const A = "/home/u/.config/vshell/plugins/aPkg/plugin.json";
const B = "/home/u/.config/vshell/plugins/zPkg/plugin.json";

test("equal-priority reads pick the same path in either order, a rescan replaces its own record, and the path breaks ties within one priority only", () => {
    let first = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, incomingPath: B });
    assert.equal(first.action, "replace", "the first read of an unowned id owns it whichever path it is");
    let second = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, incomingPath: A, existing: owner("user", { manifestPath: B }) });
    assert.equal(second.action, "replace", "the lower path takes the id from the higher one");

    first = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, incomingPath: A });
    assert.equal(first.action, "replace");
    second = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, incomingPath: B, existing: owner("user", { manifestPath: A }) });
    assert.equal(second.action, "shadow", "and the higher path does not take it back — the winner is the same in both orders");

    // A rescan of the current owner must replace its own record so edits do not leave stale metadata.
    const reparse = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, incomingPath: A, existing: owner("user", { manifestPath: A }) });
    assert.equal(reparse.action, "replace", "a manifest always replaces its own previous record");

    const acrossSources = verdict({ sourceTag: "system", pluginId: "somePlugin", bundledId: false, incomingPath: A, existing: owner("user", { manifestPath: B }) });
    assert.equal(acrossSources.action, "shadow", "the path only breaks ties within one priority");
});

// Displacement can occur within one source directory. It must still tear down the prior
// loaded component before installing the replacement record.
test("_displacesLoadedPackage is true for a loaded incumbent at another path only", () => {
    assert.equal(
        displaces({ source: "user", loaded: true, manifestPath: A }, B), true,
        "a different path is a takeover even when both packages are user-source"
    );
    assert.equal(
        displaces({ source: "bundled", loaded: true, manifestPath: "/usr/share/vgs/plugins/x/plugin.json" }, A), true,
        "and across sources, as before"
    );
    assert.equal(
        displaces({ source: "user", loaded: true, manifestPath: A }, A), false,
        "re-parsing a package's own manifest displaces nothing — it keeps its registration"
    );
    assert.equal(
        displaces({ source: "user", loaded: false, manifestPath: A }, B), false,
        "a package that is not loaded has nothing to tear down"
    );
    assert.equal(displaces(null, A), false, "and an unowned id has no incumbent at all");
});

test("no unmarked package may own a bundled id or be auto-loaded", () => {
    for (const sourceTag of ["user", "system"]) {
        for (const manifest of [{}, { overrides: false }, { overrides: "other" }, { overrides: [] }]) {
            const decided = verdict({ sourceTag: sourceTag, manifest: manifest, existing: owner("bundled"), userEnabled: true });
            assert.equal(decided.action, "block", "no unmarked package may own a bundled id");
            assert.equal(decided.enabled, false, "and none of them may be auto-loaded");
        }
    }
});

test("a shipped package is never blocked from its own id and is always available", () => {
    for (const existing of [null, owner("bundled"), owner("user"), owner("user", { overridesBundled: true })]) {
        const decided = verdict({ sourceTag: "bundled", existing: existing });
        assert.notEqual(decided.action, "block", "a shipped package is never blocked from its own id");
        assert.equal(decided.alwaysAvailable, true, "and is always available whatever it competes with");
    }
});

const VERSION_SERVICE = path.join(
    REPO, "quickshell", "vshell", "Services", "ShellVersionService.qml"
);
const versionSource = fs.readFileSync(VERSION_SERVICE, "utf8");
const versionMatch = versionSource.match(/\/\/ BEGIN VERSION POLICY\n([\s\S]*?)\/\/ END VERSION POLICY/);
assert.ok(versionMatch, "ShellVersionService.qml must carry the VERSION POLICY markers");

// Use the runtime comparator so a more permissive test substitute cannot accept an invalid requirement.
const { checkVersionRequirement, parseVersion } = new Function(
    `${versionMatch[1]}\nreturn { checkVersionRequirement, parseVersion };`
)();

const shellVersion = fs.readFileSync(path.join(REPO, "VERSION"), "utf8").trim();
test("VERSION is semver and the extracted comparator can refuse and accept", () => {
    assert.ok(/^\d+\.\d+\.\d+/.test(shellVersion), `VERSION must be semver, got "${shellVersion}"`);
    const parsedShell = parseVersion(shellVersion);

    // Require the comparator to reject an incompatible requirement before checking shipped manifests.
    assert.equal(checkVersionRequirement(">=999.0.0", parsedShell), false, "the extracted comparator must be able to refuse a requirement");
    assert.equal(checkVersionRequirement(">=0.0.0", parsedShell), true, "and to accept one");
});

test("every shipped manifest requirement accepts VERSION, so an override copied from it stays possible", () => {
    const parsedShell = parseVersion(shellVersion);
    const PLUGIN_DIR = path.join(REPO, "config", "vshell", "plugins");
    const manifestFiles = fs.readdirSync(PLUGIN_DIR, { withFileTypes: true })
        .filter(entry => entry.isDirectory())
        .map(entry => path.join(PLUGIN_DIR, entry.name, "plugin.json"))
        .filter(file => fs.existsSync(file));
    assert.ok(manifestFiles.length > 0, `no bundled plugin manifests found under ${PLUGIN_DIR}`);

    for (const file of manifestFiles) {
        const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
        const requires = manifest.requires_shell || manifest.requires_vgs || null;
        if (!requires)
            continue;
        assert.equal(
            checkVersionRequirement(requires, parsedShell),
            true,
            `${path.relative(REPO, file)}: requires_shell "${requires}" is not satisfied by VERSION ${shellVersion}. ` +
            "A bundled manifest is never judged by this constraint, but an override copied from it is, " +
            "so an unsatisfiable value here makes the plugin impossible to override (VGS-76)."
        );
    }
});
