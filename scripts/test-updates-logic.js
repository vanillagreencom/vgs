#!/usr/bin/env node
// Table-driven checks for vgs.updates pure decisions: probe normalization,
// snapshot judging, status values, cadence, staleness and TUI end detection.
// Controls edit a copy of the logic and require this suite to fail.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "plugins", "vgs.updates", "UpdatesLogic.js");
const scratch = path.join(__dirname, "..", "tmp", "test-updates-logic-" + process.pid);
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), JSON.parse(JSON.stringify(want)), message || "");

function probe(value, status = 0, stderr = "") {
  return { status, stdout: typeof value === "string" ? value : JSON.stringify(value), stderr };
}

function verify(logic) {
  const now = 1000000;
  const snapshot = logic.normalizeSnapshot({
    pkg: probe([
      { source: "pacman", count: 2, packages: [{ name: "linux", old: "1", new: "2" }], checkedAt: now - 10, error: null },
      { source: "aur", count: 1, packages: [{ name: "tool", old: "3", new: "4" }], checkedAt: now - 9, error: null },
      { source: "flatpak", count: 0, packages: [], checkedAt: now - 8, error: null },
      { source: "mise", count: null, packages: [], checkedAt: null, error: "skipped=no-check" }
    ]),
    self: probe({ version: "0.1.0", method: "checkout", package: null, current: "0.1.0.r1.g1111111", latest: "0.1.0.r2.g2222222", behind: true, error: null }),
    plugins: probe([{ id: "acme.one", behind: 2, head: "a", upstream: "b", error: null }]),
    themes: probe([{ id: "moss", behind: 0, head: "c", upstream: "c", error: null }])
  }, now);
  assert.equal(snapshot.checkedAt, now);
  same(snapshot.sources.map(s => [s.source, s.count, s.label]), [["pacman", 2, "System"], ["aur", 1, "AUR"], ["flatpak", 0, "Flatpak"], ["mise", null, "mise"], ["vgs", 1, "VGS"], ["plugins", 2, "Plugins"], ["themes", 0, "Themes"]]);
  same(snapshot.sources[4].packages, [{ name: "vgs", old: "0.1.0.r1.g1111111", new: "0.1.0.r2.g2222222" }]);
  assert.equal(logic.pendingCount(snapshot), 6);
  same(logic.checkState(snapshot, false, now, 6 * 60 * 60 * 1000), { tone: "warning", text: "mise: skipped=no-check" });
  const clean = JSON.parse(JSON.stringify(snapshot));
  clean.sources[3].error = null;
  clean.sources[3].count = 0;
  same(logic.checkState(clean, false, now, 6 * 60 * 60 * 1000), { tone: "ok", text: "Updates waiting" });
  clean.sources.forEach(s => { s.count = 0; });
  same(logic.checkState(clean, false, now, 6 * 60 * 60 * 1000), { tone: "ok", text: "Up to date" });
  same(logic.checkState(clean, true, now, 6), { tone: "info", text: "Checking" });
  clean.checkedAt = now - 13;
  same(logic.checkState(clean, false, now, 6), { tone: "warning", text: "Check stale" });
  clean.error = "exit=1";
  same(logic.checkState(clean, false, now, 6), { tone: "danger", text: "exit=1" });
  same(logic.publishValues(snapshot, false, now, 6 * 60 * 60 * 1000).pending, 6);
  assert.equal(logic.publishValues(snapshot, false, now, 6).lastCheck, now);
  assert.equal(logic.nextCheckDelay(null, false, now, 6), 0);
  assert.equal(logic.nextCheckDelay({ checkedAt: now - 2, sources: [], error: null }, false, now, 6), 4);
  assert.equal(logic.nextCheckDelay({ checkedAt: now - 7, sources: [], error: null }, false, now, 6), 0);
  assert.equal(logic.intervalMs({ intervalHours: 0 }), 3600000);
  assert.equal(logic.intervalMs({ intervalHours: 49 }), 48 * 3600000);

  same(logic.parseSnapshotText(JSON.stringify(snapshot)), { ok: true, snapshot });
  same(logic.parseSnapshotText("{"), { ok: false, error: "not-json" });
  same(logic.snapshotFromObject({ checkedAt: now, sources: [{ source: "x", count: -1 }] }), { ok: false, error: "sources.0.count" });

  const failedPlugins = logic.normalizeSnapshot({ pkg: probe([]), self: probe({ behind: false, error: null }), plugins: probe([{ id: "bad", behind: null, head: null, upstream: null, error: "fetch=bad" }]), themes: probe([]) }, now);
  const pluginRow = failedPlugins.sources.find(s => s.source === "plugins");
  same([pluginRow.count, pluginRow.error], [null, "bad: fetch=bad"]);
  const failedCommand = logic.normalizeSnapshot({ pkg: probe("", 1, "vgsh: refused: manager=none"), self: probe({ behind: false, error: null }), plugins: probe([]), themes: probe([]) }, now);
  same(failedCommand.sources[0], { source: "packages", label: "Packages", count: null, packages: [], checkedAt: null, error: "exit=1 manager=none" });

  assert.equal(logic.tuiRunEnded({}, {}), false);
  assert.equal(logic.tuiRunEnded({}, { update: { running: false, code: 0, endedAt: 10 } }), true);
  assert.equal(logic.tuiRunEnded({ update: { running: true, endedAt: null } }, { update: { running: false, code: 0, endedAt: 11 } }), true);
  assert.equal(logic.tuiRunEnded({ update: { running: false, endedAt: 12 } }, { update: { running: false, endedAt: 12 } }), false);
  assert.equal(logic.tuiRunEnded({ update: { running: false, endedAt: 12 } }, { update: { running: false, endedAt: 13 } }), true);
}

verify(load(file));

const controls = [
  ["package rows count", "total += snapshot.sources[i].count;", "total += 0;"],
  ["source errors set warning", "if (source !== null) return { tone: \"warning\", text: (source.label || source.source) + \": \" + String(source.error).slice(0, 180) };", "if (false) return { tone: \"warning\", text: \"\" };"] ,
  ["stale after twice the interval", "now - snapshot.checkedAt > 2 * intervalMs", "now - snapshot.checkedAt > 3 * intervalMs"],
  ["TUI endedAt advances", "if (Number(next.endedAt) > Number(prior.endedAt)) return true;", "if (false) return true;"],
  ["outdated error makes a source error", "errors.push(row.id + \": \" + row.error);", "count += 0;"],
  ["failed probe is reported", "if (!probe || probe.status !== 0) return { ok: false, error: commandError(name, probe || { status: null, stderr: \"\" }) };", "if (!probe || probe.status !== 0) return { ok: true, value: [] };"],
];

fs.rmSync(scratch, { recursive: true, force: true });
fs.mkdirSync(scratch, { recursive: true });
try {
  const source = fs.readFileSync(file, "utf8");
  for (const [label, needle, replacement] of controls) {
    const count = source.split(needle).length - 1;
    assert.equal(count, 1, "control pattern occurs once: " + label);
    const mutant = path.join(scratch, "UpdatesLogic.js");
    fs.writeFileSync(mutant, source.replace(needle, replacement));
    let red = false;
    try { verify(load(mutant)); } catch (e) { red = true; }
    assert.equal(red, true, "control fails without rule: " + label);
  }
} finally {
  fs.rmSync(scratch, { recursive: true, force: true });
}

console.log("test-updates-logic: ok");
