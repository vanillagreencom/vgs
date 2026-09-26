#!/usr/bin/env node
// Controls for scripts/check-manifests.js: one planted defect per rule the
// script adds beyond PluginLogic.js (duplicate id, missing entry point,
// unreadable directory, unparseable manifest), one manifest the judge itself
// refuses so a judge that passed everything would turn a row red, and the
// base listing: a directory without a manifest is not a plugin, an absent or
// unreadable base exits 2. Each row asserts the printed verdict line and the
// exit status. The check runs in a child node with an explicit environment.
// The permission rows need a uid that permissions bind; under euid 0 the
// suite reports status=not-measured and exits 77 instead of passing.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const CHECK = path.join(__dirname, "check-manifests.js");
const ENV = { PATH: process.env.PATH, LC_ALL: "C" };
const good = { schemaVersion: 1, id: "acme.one", name: "One", version: "1.0.0", author: "acme", description: "d", kinds: ["service"], entryPoints: { service: "Service.qml" } };

function plugin(dir, manifest, withEntry) {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "manifest.json"), typeof manifest === "string" ? manifest : JSON.stringify(manifest));
    if (withEntry) fs.writeFileSync(path.join(dir, "Service.qml"), "import QtQuick\nItem {}\n");
}

let failures = 0;
// rows: name, build(tmp) -> argument list, want exit, a line stdout holds
// (a string, or a function of tmp), a line it must not hold
function row(name, build, wantStatus, wantLine, forbidLine) {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "check-manifests-"));
    let proc;
    try {
        proc = spawnSync(process.execPath, [CHECK, ...build(tmp)], { encoding: "utf8", env: ENV });
    } finally {
        // A row may drop permission bits inside tmp; restore them before removal.
        spawnSync("chmod", ["-R", "u+rwx", tmp], { env: ENV });
        fs.rmSync(tmp, { recursive: true, force: true });
    }
    const want = typeof wantLine === "function" ? wantLine(tmp) : wantLine;
    const lines = proc.stdout.split("\n");
    const ok = proc.status === wantStatus && lines.some(l => l.includes(want)) && (forbidLine === undefined || !lines.some(l => l.includes(forbidLine)));
    console.log((ok ? "  ok    " : "  FAIL  ") + name + (ok ? "" : ` (exit=${proc.status} want=${want})\n${proc.stdout}${proc.stderr}`));
    if (!ok) failures += 1;
}

row("valid plugin passes", tmp => { const d = path.join(tmp, "a"); plugin(d, good, true); return ["--", d]; }, 0, "ok       acme.one");
row("missing entry point is refused and prints no ok line", tmp => { const d = path.join(tmp, "a"); plugin(d, good, false); return ["--", d]; }, 1, "entry point for service missing", "ok       acme.one");
row("duplicate id across directories is refused", tmp => { const a = path.join(tmp, "a"), b = path.join(tmp, "b"); plugin(a, good, true); plugin(b, good, true); return ["--", a, b]; }, 1, "already used by");
row("unparseable manifest is refused", tmp => { const d = path.join(tmp, "a"); plugin(d, "{not json", true); return ["--", d]; }, 1, "manifest does not parse");
row("a manifest the judge refuses is refused with the judge's line", tmp => { const d = path.join(tmp, "a"); plugin(d, Object.assign({ requires: [] }, good), true); return ["--", d]; }, 1, 'unknown key "requires"', "ok       acme.one");
row("a missing directory exits 2", tmp => ["--", path.join(tmp, "missing")], 2, tmp => "check-manifests: unreadable: " + path.join(tmp, "missing", "manifest.json") + ": ENOENT");
row("a directory named like an option after -- is a plugin directory", tmp => { const d = path.join(tmp, "--base"); plugin(d, good, true); return ["--", d]; }, 0, "ok       acme.one");
row("a base lists every plugin under it", tmp => { plugin(path.join(tmp, "a"), good, true); plugin(path.join(tmp, "b"), Object.assign({}, good, { id: "acme.two" }), true); return ["--base", tmp]; }, 0, "ok       acme.two");
row("a directory without a manifest under the base is not a plugin", tmp => { plugin(path.join(tmp, "a"), good, true); fs.mkdirSync(path.join(tmp, "notes")); return ["--base", tmp]; }, 0, "check-manifests: ok", "notes");
row("an absent base exits 2", tmp => ["--base", path.join(tmp, "missing")], 2, tmp => "check-manifests: unreadable: " + path.join(tmp, "missing") + ": cannot list: ");
row("an unknown option exits 2", tmp => ["--frob"], 2, "check-manifests: refused: option=--frob");
// Permission bits bind only a non-root uid.
if (process.getuid() !== 0) {
    row("a plugin directory the scan cannot read exits 2", tmp => { plugin(path.join(tmp, "a"), good, true); plugin(path.join(tmp, "locked"), good, true); fs.chmodSync(path.join(tmp, "locked"), 0o000); return ["--base", tmp]; }, 2, tmp => "check-manifests: unreadable: " + path.join(tmp, "locked") + ": cannot read manifest: Permission denied");
    row("an entry point that cannot be checked exits 2 and is not called missing", tmp => { const d = path.join(tmp, "a"); plugin(d, Object.assign({}, good, { entryPoints: { service: "locked/Service.qml" } }), false); fs.mkdirSync(path.join(d, "locked")); fs.writeFileSync(path.join(d, "locked", "Service.qml"), ""); fs.chmodSync(path.join(d, "locked"), 0o000); return ["--", d]; }, 2, tmp => "check-manifests: unreadable: " + path.join(tmp, "a", "locked", "Service.qml") + ": EACCES", "missing");
}

if (failures > 0) { console.log("test-check-manifests: failed=" + failures); process.exit(1); }
// Under euid 0 the permission rows did not run: an unmeasured suite, not a pass.
if (process.getuid() === 0) { console.log("test-check-manifests: status=not-measured reason=euid-0"); process.exit(77); }
console.log("test-check-manifests: ok");
