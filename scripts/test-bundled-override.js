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
//
// It then checks the shipped plugin manifests against VERSION, using the
// runtime's own comparator (extracted the same way from ShellVersionService).
// A bundled manifest's requires_shell is never enforced, so an impossible one
// is inert where it is written and fires only where it is copied: an override
// is normally a copy of the shipped manifest, so it inherits the constraint and
// is demoted by the version gate. Every bundled manifest shipped `>=1.0.0`
// against a 0.1.0 shell, which made overriding any bundled plugin impossible
// and had nothing to catch it. (VGS-76)

"use strict";

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
        existingPriority: existing ? PRIORITY[existing.source] : -1,
        incomingPath: opts.incomingPath,
        existingPath: existing ? existing.manifestPath : ""
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

// --- VGS-75: equal priority must not be decided by completion order --------

// Two user packages claiming one id have equal priority, and the manifest reads
// that produce them are FileViews that settle in whatever order the filesystem
// hands back. Under `>=` the last read to finish won, so the same two packages
// on disk could own the id differently across rescans. The tie-break is the
// manifest path, so both arrival orders have to name the same winner.
const A = "/home/u/.config/vshell/plugins/aPkg/plugin.json";
const B = "/home/u/.config/vshell/plugins/zPkg/plugin.json";

let first = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, incomingPath: B });
assert.equal(first.action, "replace", "the first read of an unowned id owns it whichever path it is");
let second = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, incomingPath: A, existing: owner("user", { manifestPath: B }) });
assert.equal(second.action, "replace", "the lower path takes the id from the higher one");

first = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, incomingPath: A });
assert.equal(first.action, "replace");
second = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, incomingPath: B, existing: owner("user", { manifestPath: A }) });
assert.equal(second.action, "shadow", "and the higher path does not take it back — the winner is the same in both orders");

// Re-parsing the owner's own manifest (a rescan, or an edit in place) is an
// equal-priority collision with itself and must still replace its own record,
// or `plugin-scan rescan` would leave the stale record owning the id.
const reparse = verdict({ sourceTag: "user", pluginId: "somePlugin", bundledId: false, incomingPath: A, existing: owner("user", { manifestPath: A }) });
assert.equal(reparse.action, "replace", "a manifest always replaces its own previous record");

// Priority still outranks the path: a lower path in a lower-priority directory
// does not beat a higher-priority one.
const acrossSources = verdict({ sourceTag: "system", pluginId: "somePlugin", bundledId: false, incomingPath: A, existing: owner("user", { manifestPath: B }) });
assert.equal(acrossSources.action, "shadow", "the path only breaks ties within one priority");

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

// --- VGS-76: shipped manifests must satisfy the shell they ship with --------

const VERSION_SERVICE = path.join(
    REPO, "quickshell", "vshell", "Services", "ShellVersionService.qml"
);
const versionSource = fs.readFileSync(VERSION_SERVICE, "utf8");
const versionMatch = versionSource.match(/\/\/ BEGIN VERSION POLICY\n([\s\S]*?)\/\/ END VERSION POLICY/);
assert.ok(versionMatch, "ShellVersionService.qml must carry the VERSION POLICY markers");

// Same extraction trick, and for the same reason: the requirement has to be
// judged by the comparator that judges it at runtime, not by a stand-in that
// could be more permissive than the shell.
const { checkVersionRequirement, parseVersion } = new Function(
    `${versionMatch[1]}\nreturn { checkVersionRequirement, parseVersion };`
)();

const shellVersion = fs.readFileSync(path.join(REPO, "VERSION"), "utf8").trim();
assert.ok(/^\d+\.\d+\.\d+/.test(shellVersion), `VERSION must be semver, got "${shellVersion}"`);
const parsedShell = parseVersion(shellVersion);

// The instrument before the measurement: a comparator that answered `true` to
// everything would pass every manifest below while checking nothing.
assert.equal(checkVersionRequirement(">=999.0.0", parsedShell), false, "the extracted comparator must be able to refuse a requirement");
assert.equal(checkVersionRequirement(">=0.0.0", parsedShell), true, "and to accept one");

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

console.log(`bundled-override policy checks passed (${manifestFiles.length} shipped manifests judged against VERSION ${shellVersion})`);
