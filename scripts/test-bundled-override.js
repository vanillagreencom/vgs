#!/usr/bin/env node

// Exercises the bundled-id override policy in PluginService.
//
// Three rules meet in one decision and none of them can be checked by the QML
// smoke, which only ever sees the bundled directory:
//
//   * a package that reuses a shipped id without declaring an override is
//     inert — id collision alone must not auto-enable and load something the
//     user never turned on (VGS-26);
//   * a declared override inherits always-available, because an override that
//     owns the id and never starts is the hole VGS-13 closed;
//   * always-available is what makes disablePlugin refuse, so it is also what
//     the Settings UI keys its "no disable affordance" on (VGS-39).
//
// The policy is extracted verbatim from the shipped QML between its
// BEGIN/END OVERRIDE POLICY markers, so this tests the real source rather than
// a re-implementation of it.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const SERVICE = path.join(
    __dirname, "..", "quickshell", "vshell", "Services", "PluginService.qml"
);

const source = fs.readFileSync(SERVICE, "utf8");
const match = source.match(/\/\/ BEGIN OVERRIDE POLICY\n([\s\S]*?)\/\/ END OVERRIDE POLICY/);
assert.ok(match, "PluginService.qml must carry the OVERRIDE POLICY markers");

// The extracted text is plain JavaScript with no QML API use, so it evaluates
// as ordinary functions.
const { _bundledOverrideDecision: decide, _declaresBundledOverride: declares } = new Function(
    `${match[1]}\nreturn { _bundledOverrideDecision, _declaresBundledOverride };`
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
        existingPriority: existing ? PRIORITY[existing.source] : -1
    });
}

// --- the override claim itself -------------------------------------------

assert.equal(declares({ overrides: "vgsMenu" }, "vgsMenu"), true, "the id names the claim");
assert.equal(declares({ overrides: "somethingElse" }, "vgsMenu"), false, "a claim on another id is not a claim on this one");
assert.equal(declares({ overrides: true }, "vgsMenu"), true, "`true` claims whatever id the manifest declares");
assert.equal(declares({ overrides: ["a", "vgsMenu"] }, "vgsMenu"), true, "a list containing the id claims it");
assert.equal(declares({ overrides: ["a", "b"] }, "vgsMenu"), false, "a list without the id does not");
assert.equal(declares({}, "vgsMenu"), false, "no marker is no claim");
assert.equal(declares({ overrides: false }, "vgsMenu"), false, "an explicit false is no claim");

// --- the shipped package -------------------------------------------------

let v = verdict({ sourceTag: "bundled" });
assert.equal(v.action, "replace", "a bundled manifest with no incumbent owns its id");
assert.equal(v.alwaysAvailable, true, "bundled packages are always available");
assert.equal(v.enabled, true, "and therefore auto-enabled without a user setting");
assert.equal(v.overridesBundled, false, "a bundled package does not override itself");

// --- VGS-26: collision alone grants nothing ------------------------------

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

// --- a declared override -------------------------------------------------

v = verdict({ sourceTag: "user", manifest: { overrides: "vgsMenu" }, existing: owner("bundled") });
assert.equal(v.action, "replace", "a declared override takes the id");
assert.equal(v.alwaysAvailable, true, "and inherits always-available");
assert.equal(v.enabled, true, "so it loads without the user enabling it (the VGS-13 hole)");
assert.equal(v.overridesBundled, true);

// --- scan order ----------------------------------------------------------

// The user directory can be read before the bundled one, so the id is not yet
// known to be bundled when the package that reuses it is parsed.
v = verdict({ sourceTag: "user", bundledId: false });
assert.equal(v.action, "replace", "an unknown id is just an ordinary plugin");
assert.equal(v.enabled, false, "which stays disabled until the user enables it");
assert.equal(v.alwaysAvailable, false);

v = verdict({ sourceTag: "user", manifest: { overrides: "vgsMenu" }, bundledId: false });
assert.equal(v.overridesBundled, true, "the claim is recorded even before the shipped package is seen");
assert.equal(v.alwaysAvailable, false, "but grants nothing until there is something to override");

// The bundled manifest arriving second must be able to take its id back from a
// bare collision, and must NOT take it from a declared override.
v = verdict({ sourceTag: "bundled", existing: owner("user") });
assert.equal(v.action, "reclaim", "the shipped package reclaims its id from a bare collision");
assert.equal(v.alwaysAvailable, true);

v = verdict({ sourceTag: "bundled", existing: owner("user", { overridesBundled: true }) });
assert.equal(v.action, "shadow", "a declared override keeps the id whichever order the scan ran in");

v = verdict({ sourceTag: "bundled", existing: owner("system") });
assert.equal(v.action, "reclaim", "a system collision is reclaimed the same way");

// --- unrelated ids are untouched -----------------------------------------

v = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, existing: owner("system") });
assert.equal(v.action, "replace", "user still outranks system for an ordinary id");
assert.equal(v.enabled, false, "and ordinary plugins stay opt-in");

v = verdict({ sourceTag: "system", pluginId: "somePlugin", bundledId: false, existing: owner("user") });
assert.equal(v.action, "shadow", "system does not outrank user");

v = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, userEnabled: true });
assert.equal(v.enabled, true, "an enabled ordinary plugin loads");

v = verdict({ sourceTag: "user", pluginId: "someWidget", bundledId: false, isPureDesktop: true });
assert.equal(v.enabled, true, "desktop-only packages are enabled by their instances, as before");

// --- the invariant, stated directly --------------------------------------

for (const sourceTag of ["user", "system"]) {
    for (const manifest of [{}, { overrides: false }, { overrides: "other" }, { overrides: [] }]) {
        const decided = verdict({ sourceTag: sourceTag, manifest: manifest, existing: owner("bundled"), userEnabled: true });
        assert.equal(decided.action, "block", "no unmarked package may own a bundled id");
        assert.equal(decided.enabled, false, "and none of them may be auto-loaded");
    }
}

for (const existing of [null, owner("bundled"), owner("user"), owner("user", { overridesBundled: true })]) {
    const decided = verdict({ sourceTag: "bundled", existing: existing });
    assert.notEqual(decided.action, "block", "a shipped package is never blocked from its own id");
    assert.equal(decided.alwaysAvailable, true, "and is always available whatever it competes with");
}

console.log("bundled-override policy checks passed");
