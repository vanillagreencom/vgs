#!/usr/bin/env node

// Exercises the rule that decides when a plugin is REPORTED as withheld on its
// declared `requires_shell` (VGS-89).
//
// A bundled manifest's constraint is inert — always-available by construction,
// audited at its source and never enforced — so reporting one would tell a user
// a package is unavailable while it is loaded and working. For every other
// source the constraint IS enforced, and an enforced constraint that reports
// nothing is indistinguishable from the package not existing, which is the
// condition that made VGS-76 hard to diagnose. The rule therefore has to say
// "withheld" in exactly one set of circumstances and stay silent in every
// other, and nothing in the QML smoke can see any of it: the smoke only ever
// loads the bundled directory, whose ids are precisely the exempt case.
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

function judge(plugin, shellSemver) {
    return withheld(plugin, shellSemver, compatible(plugin.requires_shell, shellSemver));
}

// A constraint this shell cannot satisfy, and one it trivially can, both
// derived from VERSION so the fixtures cannot drift away from the repo.
const major = parseVersion(SHELL).major;
const IMPOSSIBLE = `>=${major + 1}.0.0`;
const SATISFIED = ">=0.0.1";

assert.equal(
    judge({ source: "system", requires_shell: IMPOSSIBLE }, SHELL), true,
    "a system package whose constraint this shell cannot meet is withheld and must say so"
);

assert.equal(
    judge({ source: "user", requires_shell: IMPOSSIBLE }, SHELL), true,
    "a user package is enforced against exactly as a system one is"
);

assert.equal(
    judge({ source: "bundled", requires_shell: IMPOSSIBLE }, SHELL), false,
    "a bundled id is always-available, so its unmet constraint is inert — reporting it " +
    "would call a loaded, working package unavailable"
);

assert.equal(
    judge({ source: "system", requires_shell: SATISFIED }, SHELL), false,
    "a satisfied constraint withholds nothing"
);

assert.equal(
    judge({ source: "system" }, SHELL), false,
    "a package with no declaration has nothing to be withheld on"
);

assert.equal(
    judge({ source: "system", requires_shell: IMPOSSIBLE }, ""), false,
    "shell version detection is asynchronous; before it lands an unresolved version parses " +
    "as 0.0.0 and fails every '>=', so reporting then would be a lie that clears itself"
);

assert.equal(
    withheld(null, SHELL, false), false,
    "an id with no record is not a withheld package"
);

// The shipped manifests, judged the same way. None of them may report as
// withheld: they are all bundled, and the exemption above is what guarantees it
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
        judge({ source: "bundled", requires_shell: requires }, SHELL), false,
        `${manifest.id}: a shipped manifest must never report as withheld`
    );
}

console.log(
    `plugin requirement-report checks passed ` +
    `(${shipped.length} shipped manifests, shell VERSION ${SHELL})`
);
