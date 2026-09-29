#!/usr/bin/env node
// Table-driven checks for vgs.updates pure decisions: probe normalization,
// snapshot judging, status values, cadence, staleness, TUI end detection, and
// what the bar widget and the flyout draw from the published values.
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
  same(snapshot.sources.map(s => [s.source, s.count, s.label]), [["pacman", 2, "System"], ["aur", 1, "AUR"], ["flatpak", 0, "Flatpak"], ["mise", null, "mise"], ["vgs", 1, "VGS"], ["plugins", 1, "Plugins"], ["themes", 0, "Themes"]]);
  same(snapshot.sources[4].packages, [{ name: "vgs", old: "0.1.0.r1.g1111111", new: "0.1.0.r2.g2222222" }]);
  assert.equal(logic.pendingCount(snapshot), 5);
  same(logic.checkState(snapshot, false, now, 6 * 60 * 60 * 1000, ""), { tone: "warning", text: "mise: skipped=no-check" });
  const clean = JSON.parse(JSON.stringify(snapshot));
  clean.sources[3].error = null;
  clean.sources[3].count = 0;
  same(logic.checkState(clean, false, now, 6 * 60 * 60 * 1000, ""), { tone: "ok", text: "Updates waiting" });
  clean.sources.forEach(s => { s.count = 0; });
  same(logic.checkState(clean, false, now, 6 * 60 * 60 * 1000, ""), { tone: "ok", text: "Up to date" });
  same(logic.checkState(clean, true, now, 6, ""), { tone: "info", text: "Checking" });
  clean.checkedAt = now - 13;
  same(logic.checkState(clean, false, now, 6, ""), { tone: "warning", text: "Check stale" });
  clean.error = "exit=1";
  same(logic.checkState(clean, false, now, 6, ""), { tone: "danger", text: "exit=1" });
  same(logic.publishValues(snapshot, false, now, 6 * 60 * 60 * 1000, "").pending, 5);
  assert.equal(logic.publishValues(snapshot, false, now, 6, "").lastCheck, now);
  assert.equal(logic.nextCheckDelay(null, false, now, 6, null), 0);
  assert.equal(logic.nextCheckDelay({ checkedAt: now - 2, sources: [], error: null }, false, now, 6, null), 4);
  assert.equal(logic.nextCheckDelay({ checkedAt: now - 7, sources: [], error: null }, false, now, 6, null), 0);
  assert.equal(logic.intervalMs({ intervalHours: 0 }), 3600000);
  assert.equal(logic.intervalMs({ intervalHours: 49 }), 48 * 3600000);
  same(snapshot.sources[5].packages, [{ name: "acme.one", old: "a", new: "b", behind: 2 }]);
  same(logic.checkState(clean, false, now, 6, "exit=2 failed"), { tone: "danger", text: "exit=2 failed" });
  same(logic.statusWrites({}, { pending: 1, lastCheck: null, checkState: { tone: "ok", text: "Up to date" }, sources: [] }).map(w => w.key), ["pending", "checkState", "sources"]);
  same(logic.statusWrites({ pending: 1 }, { pending: 1, checkState: { tone: "ok", text: "Up to date" } }).map(w => w.key), ["checkState"]);
  assert.equal(logic.nextCheckDelay(snapshot, false, now + 1000, 99999999, now), logic.RETRY_AFTER_FAILURE_MS - 1000);
  assert.equal(logic.nextCheckDelay(snapshot, false, now + logic.RETRY_AFTER_FAILURE_MS, 6, now), 0);
  assert.equal(logic.nextTimerDelay({ checkedAt: now - 7, sources: [], error: null }, false, now, 6, null, true), 0);
  assert.equal(logic.nextTimerDelay(null, false, now, 6, null, true), 0);
  assert.equal(logic.nextTimerDelay(null, false, now, 6, null, false), null);
  const many = logic.normalizeSnapshot({
    pkg: probe([{ source: "pacman", count: 3000, packages: Array.from({ length: 3000 }, (_, i) => ({ name: "pkg-" + i + "-".repeat(120), old: "1".repeat(120), new: "2".repeat(120) })), checkedAt: now, error: null }]),
    self: probe({ behind: false, error: null }),
    plugins: probe([]),
    themes: probe([])
  }, now);
  const bounded = logic.publishValues(many, false, now, 6 * 60 * 60 * 1000, "");
  assert.equal(bounded.pending, 3000);
  assert.equal(bounded.sources[0].packages.length, logic.PUBLISHED_PACKAGES_PER_SOURCE_MAX);
  assert.equal(bounded.sources[0].more, 3000 - logic.PUBLISHED_PACKAGES_PER_SOURCE_MAX);
  assert.equal(bounded.sources[0].packages[0].name.length, logic.PUBLISHED_PACKAGE_TEXT_MAX);
  assert.equal(logic.statusRecordBytes(bounded) < logic.STATUS_MAX_BYTES, true);
  assert.equal(logic.statusRecordBytes(Object.assign({}, bounded, { sources: many.sources })) > logic.STATUS_MAX_BYTES, true);

  same(logic.parseSnapshotText(JSON.stringify(snapshot)), { ok: true, snapshot });
  same(logic.parseSnapshotText("{"), { ok: false, error: "not-json" });
  same(logic.snapshotFromObject({ checkedAt: now, sources: [{ source: "x", count: -1 }] }), { ok: false, error: "sources.0.count" });

  const failedPlugins = logic.normalizeSnapshot({ pkg: probe([]), self: probe({ behind: false, error: null }), plugins: probe([{ id: "bad", behind: null, head: null, upstream: null, error: "fetch=bad" }, { id: "good", behind: 3, head: "a", upstream: "b", error: null }]), themes: probe([]) }, now);
  const pluginRow = failedPlugins.sources.find(s => s.source === "plugins");
  same([pluginRow.count, pluginRow.error], [1, "bad: fetch=bad"]);
  same(logic.checkState(failedPlugins, false, now, 6 * 60 * 60 * 1000, ""), { tone: "warning", text: "Plugins: bad: fetch=bad" });
  const untracked = logic.normalizeSnapshot({ pkg: probe([]), self: probe({ behind: false, error: null }), plugins: probe([{ id: "local", behind: null, head: null, upstream: null, error: "not-a-checkout=/home/u/.config/vgs/plugins/local" }]), themes: probe([]) }, now);
  const untrackedRow = untracked.sources.find(s => s.source === "plugins");
  same([untrackedRow.count, untrackedRow.packages, untrackedRow.error], [0, [], null]);
  const noManager = logic.normalizeSnapshot({ pkg: probe([]), self: probe({ behind: false, error: null }), plugins: probe([]), themes: probe([]) }, now);
  same(noManager.sources.map(s => s.source), ["vgs", "plugins", "themes"]);
  const failedPkg = logic.normalizeSnapshot({ pkg: probe("", 1, "vgsh: refused: lock=failed"), self: probe({ behind: false, error: null }), plugins: probe([]), themes: probe([]) }, now);
  same(failedPkg.sources[0], { source: "packages", label: "Packages", count: null, packages: [], checkedAt: null, error: "exit=1 lock=failed" });

  assert.equal(logic.tuiRunEnded({}, {}), false);
  assert.equal(logic.tuiRunEnded(null, { update: { running: false, code: 0, endedAt: 10 } }), false);
  assert.equal(logic.tuiRunEnded({}, { update: { running: false, code: 0, endedAt: 10 } }), true);
  assert.equal(logic.tuiRunEnded({ update: { running: true, endedAt: null } }, { update: { running: false, code: 0, endedAt: 11 } }), true);
  assert.equal(logic.tuiRunEnded({ update: { running: false, endedAt: 12 } }, { update: { running: false, endedAt: 12 } }), false);
  assert.equal(logic.tuiRunEnded({ update: { running: false, endedAt: 12 } }, { update: { running: false, endedAt: 13 } }), true);

  same([logic.publishValues(snapshot, true, now, 6, "").checking, logic.publishValues(snapshot, false, now, 6, "").checking], [true, false]);
  same(logic.statusWrites({ checking: true }, { checking: false }), [{ key: "checking", value: false }]);
  verifyView(logic);
}

// The widget and the flyout, from published values as the service writes
// them. Each row: [name, values, hideWhenCurrent, the widget's view].
function verifyView(logic) {
  const ok = { tone: "ok", text: "Up to date" };
  const widgetRows = [
    ["current", { pending: 0, checkState: ok, checking: false }, false, { state: "current", icon: "refresh-cw", tone: "calm", spinning: false, badge: "", badgeTone: "neutral", hidden: false }],
    ["current hidden", { pending: 0, checkState: ok, checking: false }, true, { state: "current", icon: "refresh-cw", tone: "calm", spinning: false, badge: "", badgeTone: "neutral", hidden: true }],
    ["pending", { pending: 7, checkState: { tone: "ok", text: "Updates waiting" }, checking: false }, true, { state: "pending", icon: "refresh-cw", tone: "accent", spinning: false, badge: "7", badgeTone: "accent", hidden: false }],
    ["pending past the badge", { pending: 150, checkState: { tone: "ok", text: "Updates waiting" } }, false, { state: "pending", icon: "refresh-cw", tone: "accent", spinning: false, badge: "99+", badgeTone: "accent", hidden: false }],
    ["failed source", { pending: 3, checkState: { tone: "warning", text: "AUR: exit=1 network down" }, checking: false }, true, { state: "attention", icon: "triangle-alert", tone: "warning", spinning: false, badge: "3", badgeTone: "warning", hidden: false }],
    ["failed check", { pending: 0, checkState: { tone: "danger", text: "exit=2 lock" }, checking: false }, true, { state: "attention", icon: "triangle-alert", tone: "warning", spinning: false, badge: "", badgeTone: "warning", hidden: false }],
    ["stale", { pending: 0, checkState: { tone: "warning", text: "Check stale" }, checking: false }, true, { state: "attention", icon: "triangle-alert", tone: "warning", spinning: false, badge: "", badgeTone: "warning", hidden: false }],
    ["checking", { pending: 2, checkState: { tone: "info", text: "Checking" }, checking: true }, true, { state: "checking", icon: "refresh-cw", tone: "calm", spinning: true, badge: "2", badgeTone: "accent", hidden: false }],
    ["not checked", { checkState: { tone: "info", text: "Not checked" }, checking: false }, true, { state: "unchecked", icon: "circle-dashed", tone: "calm", spinning: false, badge: "", badgeTone: "neutral", hidden: false }],
    ["nothing published", {}, true, { state: "unchecked", icon: "circle-dashed", tone: "calm", spinning: false, badge: "", badgeTone: "neutral", hidden: false }]
  ];
  for (const [name, values, hide, want] of widgetRows) same(logic.widgetView(values, hide), want, "widget " + name);
  assert.throws(() => logic.widgetView({ checkState: { tone: "loud", text: "x" } }, false), /checkState tone "loud"/);

  const summaryRows = [
    [{ pending: 0, checkState: ok }, "Up to date"],
    [{ pending: 1, checkState: ok }, "1 update waiting"],
    [{ pending: 7, checkState: ok }, "7 updates waiting"],
    [{ pending: 7, checkState: { tone: "warning", text: "Check stale" } }, "Check stale"],
    [{ checking: true }, "Checking for updates"],
    [{}, "Not checked yet"]
  ];
  for (const [values, want] of summaryRows) assert.equal(logic.summaryText(values), want);

  const now = new Date(2026, 8, 29, 14, 30).getTime();
  const today = new Date(2026, 8, 29, 14, 2).getTime();
  const yesterday = new Date(2026, 8, 28, 23, 59).getTime();
  const when = (ms, withDate) => (withDate ? "date+" : "") + (ms === today ? "14:02" : "23:59");
  assert.equal(logic.checkedText(today, now, when), "Checked 14:02");
  assert.equal(logic.checkedText(yesterday, now, when), "Checked date+23:59");
  assert.equal(logic.checkedText(undefined, now, when), "Never checked");

  const sources = [
    { source: "pacman", label: "System", count: 2, packages: [{ name: "linux", old: "6.1", new: "6.2" }, { name: "mesa", old: null, new: "25.2" }], checkedAt: today, error: null, more: 3 },
    { source: "aur", label: "AUR", count: null, packages: [], checkedAt: null, error: "exit=1 network down", more: 0 },
    { source: "flatpak", label: "Flatpak", count: 0, packages: [], checkedAt: today, error: null, more: 0 },
    { source: "plugins", label: "Plugins", count: 1, packages: [{ name: "acme.one", old: "a".repeat(40), new: "b".repeat(40), behind: 2 }], checkedAt: today, error: "bad: fetch=bad", more: 0 },
    { source: "later", label: "later", count: 1, packages: [{ name: "x", old: null, new: null }], checkedAt: today, error: null, more: 0 }
  ];
  const values = { pending: 4, lastCheck: today, checkState: { tone: "warning", text: "AUR: exit=1 network down" }, checking: false, sources };
  assert.equal(logic.widgetTooltip(values, now, when), ["AUR: exit=1 network down", "System: 2", "AUR: check failed", "Flatpak: 0", "Plugins: 1", "later: 1", "Checked 14:02"].join("\n"));
  assert.equal(logic.widgetTooltip({}, now, when), "Not checked yet\nNever checked");
  same(logic.panelRows(values), [
    { key: "pacman", source: "pacman", label: "System", icon: "package", secondary: "2 updates", badge: "2", badgeTone: "accent", updatable: true, lines: ["linux 6.1 → 6.2", "mesa → 25.2"], more: "+3 more" },
    { key: "aur", source: "aur", label: "AUR", icon: "package-open", secondary: "exit=1 network down", badge: "Failed", badgeTone: "warning", updatable: false, lines: [], more: "" },
    { key: "flatpak", source: "flatpak", label: "Flatpak", icon: "boxes", secondary: "Up to date", badge: "0", badgeTone: "neutral", updatable: false, lines: [], more: "" },
    { key: "plugins", source: "plugins", label: "Plugins", icon: "puzzle", secondary: "bad: fetch=bad", badge: "1", badgeTone: "warning", updatable: true, lines: ["acme.one: 2 commits behind"], more: "" },
    { key: "later", source: "later", label: "later", icon: "package", secondary: "1 update", badge: "1", badgeTone: "accent", updatable: true, lines: ["x"], more: "" }
  ]);
  same(logic.panelRows({}), []);

  same(logic.tuiRequest("all"), { name: "update", args: [] });
  same(logic.tuiRequest("source", "aur"), { name: "update-source", args: ["aur"] });
  same(logic.tuiRequest("log"), { name: "log", args: [] });
  assert.throws(() => logic.tuiRequest("source", ""), /needs a source/);
  assert.throws(() => logic.tuiRequest("everything"), /is not one of all, source, log/);
  same(["ok", "started", "queued", "refused: tui=update reason=busy"].map(logic.replyLine), ["", "", "", "refused: tui=update reason=busy"]);
}

verify(load(file));

const controls = [
  ["package rows count", "total += snapshot.sources[i].count;", "total += 0;"],
  ["outdated rows count once", "count += 1;", "count += behind;"],
  ["outdated packages keep behind", "behind: behind", "oldBehind: behind"],
  ["check failure wins state", "if (checkFailure !== null && checkFailure !== undefined && checkFailure !== \"\") return { tone: \"danger\", text: String(checkFailure).slice(0, 200) };", "if (false) return { tone: \"danger\", text: \"\" };"],
  ["status writes skip unchanged", "if (!hasOwn(before, key) || !sameJson(before[key], next[key])) out.push({ key: key, value: clone(next[key]) });", "out.push({ key: key, value: clone(next[key]) });"],
  ["failure retry uses short delay", "failedAt + RETRY_AFTER_FAILURE_MS - now", "failedAt + interval - now"],
  ["a failed package probe is one packages row", "if (!parsed.ok) return [sourceRow(\"packages\", null, [], null, parsed.error)];", "if (!parsed.ok) return [];"],
  ["published packages are bounded", "var limit = Math.min(row.packages.length, PUBLISHED_PACKAGES_PER_SOURCE_MAX);", "var limit = row.packages.length;"],
  ["published rows carry the omitted package count", "made.more = Math.max(0, row.packages.length - packages.length);", "made.more = 0;"],
  ["published package text is bounded", "return text.length > PUBLISHED_PACKAGE_TEXT_MAX ? text.slice(0, PUBLISHED_PACKAGE_TEXT_MAX) : text;", "return text;"],
  ["source errors set warning", "if (source !== null) return { tone: \"warning\", text: (source.label || source.source) + \": \" + String(source.error).slice(0, 180) };", "if (false) return { tone: \"warning\", text: \"\" };"] ,
  ["stale after twice the interval", "now - snapshot.checkedAt >= 2 * intervalMs", "now - snapshot.checkedAt > 3 * intervalMs"],
  ["TUI endedAt advances", "if (Number(next.endedAt) > Number(prior.endedAt)) return true;", "if (false) return true;"],
  ["outdated error makes a source error", "if (!UNTRACKED_REFUSAL.test(String(row.error))) errors.push(row.id + \": \" + row.error);", "count += 0;"],
  ["an untracked directory is not a source error", "var UNTRACKED_REFUSAL = /^not-a-checkout=/;", "var UNTRACKED_REFUSAL = /^$never/;"],
  ["one failing checkout keeps the others' count", "return sourceRow(source, count, packages, checkedAt, errors.length > 0 ? errors.join(\"; \") : null);", "return sourceRow(source, errors.length > 0 ? null : count, packages, checkedAt, errors.length > 0 ? errors.join(\"; \") : null);"],
  ["only a current widget hides", "hidden: hideWhenCurrent === true && state === \"current\"", "hidden: hideWhenCurrent === true && state !== \"checking\""],
  ["a warning or danger check draws attention", "case \"danger\": return \"attention\";", "case \"danger\": return \"current\";"],
  ["a running check spins", "if (v.checking === true) return \"checking\";", "if (false) return \"checking\";"],
  ["pending needs a count", "case \"ok\": return pendingOf(v) > 0 ? \"pending\" : \"current\";", "case \"ok\": return \"pending\";"],
  ["the badge is capped", "return count > BADGE_COUNT_MAX ? BADGE_COUNT_MAX + \"+\" : String(count);", "return String(count);"],
  ["the checked line dates another day", "formatWhen(lastCheck, !sameLocalDay(lastCheck, now))", "formatWhen(lastCheck, false)"],
  ["a source with no count reads failed in the tooltip", "(sources[i].count === null ? \"check failed\" : sources[i].count)", "sources[i].count"],
  ["a failed source keeps its badge", "badge: failed ? \"Failed\" : badgeText(row.count),", "badge: badgeText(row.count),"],
  ["only a source with updates offers Update", "updatable: !failed && row.count > 0,", "updatable: true,"],
  ["the omitted packages read +N more", "more: typeof row.more === \"number\" && row.more > 0 ? \"+\" + row.more + \" more\" : \"\"", "more: \"\""],
  ["a checkout reads its commits behind", "if (typeof pkg.behind === \"number\") return", "if (false) return"],
  ["one source's update names its source", "return { name: \"update-source\", args: [source] };", "return { name: \"update-source\", args: [] };"],
  ["a first TUI state read counts no ended run", "if (previous === null) return false;", "if (false) return false;"],
  ["no timer before the cache read answers", "if (cacheRead !== true) return null;", "if (false) return null;"],
  ["the service publishes whether it checks", "checking: checking === true,", "checking: false,"],
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
