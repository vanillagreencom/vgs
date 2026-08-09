#!/usr/bin/env node

// Exercises the rule that decides when a plugin is REPORTED as refused on its
// declared `requires_shell` (VGS-89).
//
// The requirement is enforced in exactly one place — `_gateThenSwap` — reached
// only for a package declaring itself the override of a bundled id, or one
// displacing a package already loaded under that id. `runStartupGate()`,
// `loadPlugin()` and `reloadPlugin()` never look at it, so a unique-id user or
// system package with an impossible requirement simply loads. Verified in the
// nested sandbox: a fixture declaring `>=99.0.0` against a 0.1.0 shell answered
// `plugin-scan status` with `loaded`, identically to a control with a
// satisfiable requirement and one with none at all.
//
// That makes the rule narrow in a way that is easy to get wrong in both
// directions, and it has been wrong in both:
//
//   * report a bundled id's unmet declaration and every user sees every shipped
//     module marked unavailable while it is loaded and working;
//   * report any non-bundled package's unmet declaration and a loaded, working
//     plugin is labelled refused for an enforcement that never ran;
//   * examine only the package that WON the id and the one configuration that
//     is genuinely refused — a demoted override — is never seen, which is the
//     configuration VGS-76 was about.
//
// Nothing in the QML smoke can see any of it: the smoke loads the bundled
// directory, whose ids are precisely the exempt case.
//
// The rule is extracted verbatim from the shipped QML between its
// BEGIN/END REQUIREMENT REPORT POLICY markers, and the compatibility verdict it
// is fed comes from ShellVersionService's own VERSION POLICY comparator,
// extracted the same way. Neither is re-implemented here.

"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const REPO = path.join(__dirname, "..");
const SERVICE = path.join(REPO, "quickshell", "vshell", "Services", "PluginService.qml");
const VERSION_SERVICE = path.join(REPO, "quickshell", "vshell", "Services", "ShellVersionService.qml");

function extract(file, marker, exports) {
    const source = fs.readFileSync(file, "utf8");
    const re = new RegExp(`// BEGIN ${marker}\\n([\\s\\S]*?)// END ${marker}`);
    const match = source.match(re);
    assert.ok(match, `${path.basename(file)} must carry the ${marker} markers`);
    return new Function(`${match[1]}\nreturn { ${exports.join(", ")} };`)();
}

const { _withheldOnRequirement: withheld } =
    extract(SERVICE, "REQUIREMENT REPORT POLICY", ["_withheldOnRequirement"]);
const { parseVersion, checkVersionRequirement } =
    extract(VERSION_SERVICE, "VERSION POLICY", ["parseVersion", "checkVersionRequirement"]);

const SHELL = fs.readFileSync(path.join(REPO, "VERSION"), "utf8").trim();

// The same composition the runtime uses: PluginService.checkPluginCompatibility
// is `checkVersionRequirement(requires, parsedShellVersion)`.
function compatible(requires, shellSemver) {
    if (!requires)
        return true;
    return checkVersionRequirement(requires, parseVersion(shellSemver));
}

// `meta` is a knownManifests entry: {source, requiresShell, demoted}.
function judge(meta, shellSemver) {
    return withheld(meta, shellSemver, compatible(meta.requiresShell, shellSemver));
}

// A constraint this shell cannot satisfy, and one it trivially can, both
// derived from VERSION so the fixtures cannot drift away from the repo.
const major = parseVersion(SHELL).major;
const IMPOSSIBLE = `>=${major + 1}.0.0`;
const SATISFIED = ">=0.0.1";

assert.equal(
    judge({ source: "user", requiresShell: IMPOSSIBLE, demoted: true }, SHELL), true,
    "an override that was refused on the requirement and demoted is what this reports"
);

assert.equal(
    judge({ source: "system", requiresShell: IMPOSSIBLE, demoted: true }, SHELL), true,
    "a system-source override is refused exactly as a user one is"
);

assert.equal(
    judge({ source: "user", requiresShell: IMPOSSIBLE }, SHELL), false,
    "a package that still owns its id was never refused: the requirement is not " +
    "enforced by runStartupGate/loadPlugin/reloadPlugin, so reporting it would " +
    "label a loaded, working plugin as blocked"
);

assert.equal(
    judge({ source: "system", requiresShell: IMPOSSIBLE, demoted: false }, SHELL), false,
    "an explicit demoted:false is not a refusal either"
);

assert.equal(
    judge({ source: "bundled", requiresShell: IMPOSSIBLE, demoted: true }, SHELL), false,
    "a bundled id is always-available, so its unmet constraint is inert — reporting it " +
    "would call a loaded, working package unavailable"
);

assert.equal(
    judge({ source: "user", requiresShell: SATISFIED, demoted: true }, SHELL), false,
    "a demotion for some other reason must not be reported as a version refusal"
);

assert.equal(
    judge({ source: "user", demoted: true }, SHELL), false,
    "a package with no declaration has nothing to be refused on"
);

assert.equal(
    judge({ source: "user", requiresShell: IMPOSSIBLE, demoted: true }, ""), false,
    "shell version detection is asynchronous; before it lands an unresolved version parses " +
    "as 0.0.0 and fails every '>=', so reporting then would be a lie that clears itself"
);

assert.equal(
    withheld(null, SHELL, false), false,
    "a path with no manifest record is not a refused package"
);

// The shipped manifests, judged the same way. None of them may report as
// refused: they are all bundled, and the exemption above is what guarantees it
// — if a bundled manifest ever started reporting, every user would see every
// shipped module marked unavailable in Settings.
const pluginsDir = path.join(REPO, "config", "vshell", "plugins");
const shipped = fs.readdirSync(pluginsDir, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => path.join(pluginsDir, entry.name, "plugin.json"))
    .filter(fs.existsSync);
assert.ok(shipped.length > 0, "expected shipped plugin manifests to judge");

for (const manifestPath of shipped) {
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    const requires = manifest.requires_shell || manifest.requires_vgs || null;
    assert.equal(
        judge({ source: "bundled", requiresShell: requires, demoted: true }, SHELL), false,
        `${manifest.id}: a shipped manifest must never report as refused`
    );
}

console.log(
    `plugin requirement-report checks passed ` +
    `(${shipped.length} shipped manifests, shell VERSION ${SHELL})`
);
