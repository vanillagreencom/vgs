#!/usr/bin/env node
// Controls for scripts/check-manifests.js: one planted defect per rule the
// script adds beyond PluginLogic.js (duplicate id, missing entry point,
// unreadable directory, unparseable manifest), each asserting the printed
// verdict line and the exit status.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const CHECK = path.join(__dirname, "check-manifests.js");
const good = { schemaVersion: 1, id: "acme.one", name: "One", version: "1.0.0", author: "acme", description: "d", kinds: ["service"], entryPoints: { service: "Service.qml" } };

function plugin(dir, manifest, withEntry) {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "manifest.json"), typeof manifest === "string" ? manifest : JSON.stringify(manifest));
    if (withEntry) fs.writeFileSync(path.join(dir, "Service.qml"), "import QtQuick\nItem {}\n");
}

let failures = 0;
function row(name, build, wantStatus, wantLine, forbidLine) {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "check-manifests-"));
    const dirs = build(tmp);
    const proc = spawnSync("node", [CHECK, "--", ...dirs], { encoding: "utf8" });
    const lines = proc.stdout.split("\n");
    const ok = proc.status === wantStatus && lines.some(l => l.includes(wantLine)) && (forbidLine === undefined || !lines.some(l => l.includes(forbidLine)));
    console.log((ok ? "  ok    " : "  FAIL  ") + name + (ok ? "" : ` (exit=${proc.status})\n${proc.stdout}`));
    if (!ok) failures += 1;
    fs.rmSync(tmp, { recursive: true, force: true });
}

row("valid plugin passes", tmp => { const d = path.join(tmp, "a"); plugin(d, good, true); return [d]; }, 0, "ok       acme.one");
row("missing entry point is refused and prints no ok line", tmp => { const d = path.join(tmp, "a"); plugin(d, good, false); return [d]; }, 1, "entry point for service missing", "ok       acme.one");
row("duplicate id across directories is refused", tmp => { const a = path.join(tmp, "a"), b = path.join(tmp, "b"); plugin(a, good, true); plugin(b, good, true); return [a, b]; }, 1, "already used by");
row("unparseable manifest is refused", tmp => { const d = path.join(tmp, "a"); plugin(d, "{not json", true); return [d]; }, 1, "manifest does not parse");
row("unreadable directory exits 2", tmp => [path.join(tmp, "missing")], 2, "unreadable");

if (failures > 0) { console.log("test-check-manifests: failed=" + failures); process.exit(1); }
console.log("test-check-manifests: ok");
