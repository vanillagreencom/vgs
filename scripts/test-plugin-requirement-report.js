#!/usr/bin/env node

// Test requirement-refusal reporting with the shipped policy and runtime version comparator.
// The requirement gate applies to bundled-ID overrides and displacement of loaded packages.
// A declaration alone does not prove refusal: unique-ID packages can load without that gate.
// Inspect demoted manifests too, because the refused override need not be the winning package.

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

// Compose compatibility with the runtime comparator and parsed shell version.
function compatible(requires, shellSemver) {
    if (!requires)
        return true;
    return checkVersionRequirement(requires, parseVersion(shellSemver));
}


function judge(meta, shellSemver) {
    return withheld(meta, shellSemver, compatible(meta.refusedOnRequirement, shellSemver));
}

// Derive satisfiable and incompatible requirements from VERSION so fixture intent survives releases.
const major = parseVersion(SHELL).major;
const IMPOSSIBLE = `>=${major + 1}.0.0`;
const SATISFIED = ">=0.0.1";

assert.equal(
    judge({ source: "user", refusedOnRequirement: IMPOSSIBLE, demoted: true }, SHELL), true,
    "a package refused on the requirement is what this reports"
);

assert.equal(
    judge({ source: "system", refusedOnRequirement: IMPOSSIBLE }, SHELL), true,
    "a refusal that could NOT demote is still a refusal: there was no shipped package to " +
    "fall back to, so nothing outside pluginLoadErrors reported it before"
);

assert.equal(
    judge({ source: "user", requiresShell: IMPOSSIBLE, demoted: true }, SHELL), false,
    "demoted with an unmet constraint but no recorded refusal is a demotion with ANOTHER " +
    "cause — a failed startupCheck during the async window before the shell version " +
    "landed, when the version branch is skipped entirely. Blaming the version there " +
    "misattributes the refusal"
);

assert.equal(
    judge({ source: "user", requiresShell: IMPOSSIBLE }, SHELL), false,
    "a package that still owns its id was never refused: the requirement is not " +
    "enforced by runStartupGate/loadPlugin/reloadPlugin, so reporting it would " +
    "label a loaded, working plugin as blocked"
);

assert.equal(
    judge({ source: "bundled", refusedOnRequirement: IMPOSSIBLE, demoted: true }, SHELL), false,
    "a bundled id is always-available, so its unmet constraint is inert — reporting it " +
    "would call a loaded, working package unavailable"
);

assert.equal(
    judge({ source: "user", refusedOnRequirement: SATISFIED, demoted: true }, SHELL), false,
    "a recorded refusal whose constraint this shell now satisfies is stale — the shell " +
    "was upgraded under it; reporting would send the reader after a solved problem"
);

assert.equal(
    judge({ source: "user", demoted: true }, SHELL), false,
    "a demotion with nothing recorded has nothing to report as a version refusal"
);

assert.equal(
    judge({ source: "user", refusedOnRequirement: IMPOSSIBLE, demoted: true }, ""), false,
    "shell version detection is asynchronous; before it lands an unresolved version parses " +
    "as 0.0.0 and fails every '>=', so reporting then would be a lie that clears itself"
);

assert.equal(
    withheld(null, SHELL, false), false,
    "a path with no manifest record is not a refused package"
);

// Bundled manifests must not report refusal because their requirement declarations are not enforced there.
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
        judge({ source: "bundled", refusedOnRequirement: requires, demoted: true }, SHELL), false,
        `${manifest.id}: a shipped manifest must never report as refused`
    );
}

console.log(
    `plugin requirement-report checks passed ` +
    `(${shipped.length} shipped manifests, shell VERSION ${SHELL})`
);
