#!/usr/bin/env node
// Table-driven checks for vgs.displays' pure decisions
// (shell/plugins/vgs.displays/DisplaysLogic.js): the helper's answers
// judged, the coalescing of the helper's runs, what a brightness key and a
// linked slider change, the assignments file's judge and how its entries,
// stale ones included, apply, and the status the surfaces read. Expected
// values are written here by hand. Controls edit one rule in a copy of the
// logic and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "plugins", "vgs.displays", "DisplaysLogic.js");
const same = (got, want, message) => assert.deepEqual(JSON.parse(JSON.stringify(got)), JSON.parse(JSON.stringify(want)), message || "");

const XDR = "hidraw:devices/usb1/1-2";
const STUDIO_A = "hidraw:class/hidraw/hidraw1/device";
const STUDIO_B = "hidraw:class/hidraw/hidraw2/device";

// A `list` answer as helper/brightness.py prints it: a tiled XDR it mapped,
// two Studio Displays with one serial it could not place, a DDC display
// the user may not open, and a laptop backlight.
function listAnswer() {
  return {
    backends: { ddc: { state: "ready" }, backlight: { state: "ready" } },
    displays: [
      { id: XDR, backend: "hidraw", label: "Apple Pro Display XDR", state: "ready", percent: 50, outputs: ["DP-1", "DP-5"],
        product: "9243", identity: { parent: "devices/usb1/1-2", serial: "C02" } },
      { id: STUDIO_A, backend: "hidraw", label: "Apple Studio Display", state: "ready", percent: 30, outputs: [],
        product: "1114", identity: { parent: "class/hidraw/hidraw1/device", serial: "S" } },
      { id: STUDIO_B, backend: "hidraw", label: "Apple Studio Display", state: "ready", percent: 95, outputs: [],
        product: "1114", identity: { parent: "class/hidraw/hidraw2/device", serial: "S" } },
      { id: "ddc:HDMI-A-1", backend: "ddc", label: "DELL U2720Q", state: "no-access", percent: null, outputs: ["HDMI-A-1"] },
      { id: "backlight:intel_backlight", backend: "backlight", label: "intel_backlight", state: "ready", percent: 3, outputs: ["eDP-1"] }
    ]
  };
}

const output = (name, identifier) => ({ name, identifier, make: "Apple", model: "M", serial: "" });
const OUTPUTS = [output("DP-1", "desc:Apple ProDisplayXDR 0x03"), output("DP-5", "desc:Apple ProDisplayXDR 0x03"),
  output("DP-2", "DP-2"), output("DP-3", "DP-3"), output("HDMI-A-1", "HDMI-A-1"), output("eDP-1", "eDP-1")];
const KEY_A = "usb:class/hidraw/hidraw1/device#S";
const KEY_B = "usb:class/hidraw/hidraw2/device#S";

function verify(logic) {
  // --- The helper's answers ------------------------------------------------
  const listed = logic.parseList(JSON.stringify(listAnswer()));
  assert.equal(listed.ok, true, JSON.stringify(listed));
  same(listed.displays.map(d => [d.id, d.state, d.percent, d.identity === null ? null : d.identity.serial]),
    [[XDR, "ready", 50, "C02"], [STUDIO_A, "ready", 30, "S"], [STUDIO_B, "ready", 95, "S"],
      ["ddc:HDMI-A-1", "no-access", null, null], ["backlight:intel_backlight", "ready", 3, null]]);
  const broken = (edit) => { const a = listAnswer(); edit(a); return JSON.stringify(a); };
  const listRefusals = [
    ["not JSON", "{", "refused: list=unparsed"],
    ["helper failure", JSON.stringify({ error: "usage" }), "refused: list=helper error=\"usage\""],
    ["unknown backend state", broken(a => { a.backends.ddc.state = "fine"; }), "refused: list=shape backend=ddc"],
    ["repeated id", broken(a => { a.displays[1].id = XDR; }), "refused: list=shape display=1 field=id"],
    ["ready without a percent", broken(a => { a.displays[0].percent = null; }), "refused: list=shape display=0 field=percent"],
    ["percent past 100", broken(a => { a.displays[0].percent = 101; }), "refused: list=shape display=0 field=percent"],
    ["not ready with a percent", broken(a => { a.displays[3].percent = 40; }), "refused: list=shape display=3 field=percent"],
    ["unknown display state", broken(a => { a.displays[3].state = "asleep"; }), "refused: list=shape display=3 field=state"],
    ["empty output name", broken(a => { a.displays[0].outputs = [""]; }), "refused: list=shape display=0 field=outputs"],
    ["identity without parent", broken(a => { a.displays[0].identity = { serial: "x" }; }), "refused: list=shape display=0 field=identity"]
  ];
  for (const [name, text, want] of listRefusals) same(logic.parseList(text), { ok: false, error: want }, "parseList: " + name);

  same(logic.parseSet(JSON.stringify({ id: XDR, percent: 40 }), XDR), { ok: true, percent: 40 });
  same(logic.parseSet(JSON.stringify({ error: "state", state: "no-access", id: XDR }), XDR),
    { ok: false, error: "refused: set=helper error=\"state\" state=\"no-access\"" });
  same(logic.parseSet(JSON.stringify({ id: STUDIO_A, percent: 40 }), XDR), { ok: false, error: "refused: set=shape id=\"" + STUDIO_A + "\" percent=40" });

  // --- Runs: latest wins per display, one run in flight --------------------
  let runs = logic.emptyRuns();
  let taken = logic.takeRun(runs);
  same(taken.run, null, "nothing waits");
  runs = logic.queueSet(runs, XDR, 1);
  taken = logic.takeRun(runs);
  same(taken.run, { verb: "set", id: XDR, percent: 1 });
  runs = taken.runs;
  // A 20-event drag while the first run is in flight: 2 runs in all, the
  // last one carrying the drag's final value.
  const started = [taken.run];
  for (let p = 2; p <= 20; p++) {
    runs = logic.queueSet(runs, XDR, p);
    taken = logic.takeRun(runs);
    assert.equal(taken.run, null, "no second run while one is in flight");
    assert.equal(logic.pendingPercent(runs, XDR), p, "the drag's latest value is shown while it waits");
  }
  runs = logic.queueList(runs);
  runs = logic.queueSet(runs, STUDIO_A, 70);
  for (;;) {
    runs = logic.endRun(runs);
    taken = logic.takeRun(runs);
    if (taken.run === null) break;
    started.push(taken.run);
    runs = taken.runs;
  }
  same(started, [{ verb: "set", id: XDR, percent: 1 }, { verb: "set", id: XDR, percent: 20 }, { verb: "set", id: STUDIO_A, percent: 70 }, { verb: "list" }],
    "a drag of 20 makes 2 runs, each display keeps its place and a list waits behind the changes");
  assert.throws(() => logic.endRun(logic.emptyRuns()), /endRun with no run in flight/);
  assert.equal(logic.pendingPercent(logic.emptyRuns(), XDR), null);

  // --- Assignments ---------------------------------------------------------
  const valid = { assignments: [{ device: KEY_A, label: "Apple Studio Display", output: "DP-2" }] };
  same(logic.parseAssignments(JSON.stringify(valid)), { ok: true, entries: valid.assignments });
  const entry = (device, output) => ({ device: device, label: "L", output: output });
  const fileRefusals = [
    ["not JSON", "[", "refused: assignments=unparsed"],
    ["a list", "[]", "refused: assignments=shape want={\"assignments\":[...]}"],
    ["another key", JSON.stringify({ assignments: [], extra: 1 }), "refused: assignments=shape want={\"assignments\":[...]}"],
    ["an entry key too many", JSON.stringify({ assignments: [Object.assign(entry(KEY_A, "DP-2"), { x: 1 })] }), "refused: assignment=0 keys=[\"device\",\"label\",\"output\",\"x\"] want=device,label,output"],
    ["an empty output", JSON.stringify({ assignments: [entry(KEY_A, "")] }), "refused: assignment=0 output=\"\""],
    ["a control character", JSON.stringify({ assignments: [entry("a\nb", "DP-2")] }), "refused: assignment=0 device=\"a\\nb\""],
    ["one device twice", JSON.stringify({ assignments: [entry(KEY_A, "DP-2"), entry(KEY_A, "DP-3")] }), "refused: assignment=1 device=\"" + KEY_A + "\" reason=repeated"],
    ["past the ceiling", JSON.stringify({ assignments: Array.from({ length: 65 }, (_, i) => entry("d" + i, "DP-2")) }), "refused: assignments=too-many count=65 max=64"]
  ];
  for (const [name, text, want] of fileRefusals) same(logic.parseAssignments(text), { ok: false, error: want }, "parseAssignments: " + name);
  assert.equal(logic.assignmentsText(valid.assignments), JSON.stringify(valid, null, 2) + "\n");

  const entries = [
    entry(KEY_A, "DP-2"),
    entry(KEY_B, "DP-9"),                        // its output is gone: stale
    entry("usb:devices/usb1/1-9#S", "DP-3"),     // its device is gone: stale
    entry("usb:devices/usb1/1-2#C02", "DP-3"),   // the helper placed the XDR: unused
    entry("backlight:intel_backlight", "DP-2")   // DP-2 already shows Studio A: unused
  ];
  const resolved = logic.resolve(listed.displays, OUTPUTS, entries);
  same(resolved.assignments.map(e => e.state), ["applied", "stale", "stale", "unused", "unused"]);
  same(resolved.displays.map(d => [d.device, d.outputs, d.assigned]), [
    ["usb:devices/usb1/1-2#C02", ["DP-1", "DP-5"], false],
    [KEY_A, ["DP-2"], true],
    [KEY_B, [], false],
    ["ddc:HDMI-A-1", ["HDMI-A-1"], false],
    ["backlight:intel_backlight", ["eDP-1"], false]]);
  // An identifier two outputs share, as the tiled XDR's, places both.
  const tiled = logic.resolve(listed.displays.map(d => d.id === XDR ? Object.assign({}, d, { outputs: [] }) : d), OUTPUTS,
    [entry("usb:devices/usb1/1-2#C02", "desc:Apple ProDisplayXDR 0x03")]);
  same(tiled.displays[0].outputs, ["DP-1", "DP-5"]);

  const present = resolved.displays.map(d => d.device);
  same(logic.setAssignment(entries, KEY_B, "Apple Studio Display", "DP-3", present).map(e => [e.device, e.output]), [
    [KEY_A, "DP-2"],
    ["usb:devices/usb1/1-9#S", "DP-3"],
    ["backlight:intel_backlight", "DP-2"],
    [KEY_B, "DP-3"]], "a new choice replaces the device's own entry and a present device's entry on that output, and keeps a stale one there");
  same(logic.clearAssignment(entries, KEY_A).map(e => e.device), [KEY_B, "usb:devices/usb1/1-9#S", "usb:devices/usb1/1-2#C02", "backlight:intel_backlight"]);
  const full = Array.from({ length: 64 }, (_, i) => entry(i === 0 ? KEY_A : "gone-" + i, "X" + i));
  const capped = logic.setAssignment(full, KEY_B, "L", "DP-3", [KEY_A, KEY_B]);
  same([capped.length, capped[0].device, capped[1].device, capped[63].device], [64, KEY_A, "gone-2", KEY_B], "past the ceiling the oldest absent device's entry goes");
  same(logic.parseAssignRequest(JSON.stringify({ device: KEY_A, output: "" })), { ok: true, device: KEY_A, output: "" });
  same(logic.parseAssignRequest(JSON.stringify({ device: KEY_A })), { ok: false, error: "refused: assign=shape want={device,output}" });

  // --- Keys, scrolls and links ----------------------------------------------
  const shown = logic.displaysValue(resolved, logic.emptyRuns());
  const keySteps = [
    [50, "up", 5, 55], [98, "up", 5, 100], [3, "up", 5, 4], [4, "up", 5, 5], [5, "up", 5, 10],
    [6, "down", 5, 1], [5, "down", 5, 4], [2, "down", 5, 1], [1, "down", 5, 1], [50, "down", 10, 40]
  ];
  for (const [current, direction, step, want] of keySteps) assert.equal(logic.keyStep(current, direction, step), want, `keyStep(${current}, ${direction}, ${step})`);
  same(logic.keyChanges(shown, "DP-5", "focused", "up", 5, false), [{ id: XDR, percent: 55 }], "a key changes the display on the focused output");
  same(logic.keyChanges(shown, "DP-2", "focused", "down", 5, false), [{ id: STUDIO_A, percent: 25 }], "an assigned display takes its screen's key");
  same(logic.keyChanges(shown, "DP-3", "focused", "up", 5, false), [], "no display on the focused output changes nothing");
  same(logic.keyChanges(shown, "HDMI-A-1", "focused", "up", 5, false), [], "a display that is not ready changes nothing");
  same(logic.keyChanges(shown, "DP-1", "all", "up", 5, false),
    [{ id: XDR, percent: 55 }, { id: STUDIO_A, percent: 35 }, { id: STUDIO_B, percent: 100 }, { id: "backlight:intel_backlight", percent: 4 }],
    "keysTarget all moves every ready display by its own step");
  same(logic.keyChanges(shown, "eDP-1", "focused", "up", 5, true),
    [{ id: "backlight:intel_backlight", percent: 4 }, { id: XDR, percent: 51 }, { id: STUDIO_A, percent: 31 }, { id: STUDIO_B, percent: 96 }],
    "a linked key moves the others by the focused display's change");
  assert.throws(() => logic.keyChanges(shown, "DP-1", "every", "up", 5, false), /keysTarget "every"/);
  same(logic.linkedChanges(shown, STUDIO_A, 60, true),
    [{ id: STUDIO_A, percent: 60 }, { id: XDR, percent: 80 }, { id: STUDIO_B, percent: 100 }, { id: "backlight:intel_backlight", percent: 33 }],
    "a linked slider moves every other ready display by its delta, held to 100");
  same(logic.linkedChanges(shown, STUDIO_B, 0, true),
    [{ id: STUDIO_B, percent: 1 }, { id: XDR, percent: 1 }, { id: STUDIO_A, percent: 1 }, { id: "backlight:intel_backlight", percent: 1 }],
    "a linked slider holds every display at 1 or more");
  same(logic.linkedChanges(shown, STUDIO_A, 60, false), [{ id: STUDIO_A, percent: 60 }], "unlinked moves its own display alone");
  same(logic.linkedChanges(shown, "ddc:HDMI-A-1", 60, true), [], "a display that is not ready changes nothing");
  assert.equal(logic.scrollTarget(50, 20, 1), 70);
  assert.equal(logic.scrollTarget(50, -60, 1), 1);
  same(logic.panelOrder(shown, "DP-2").map(d => d.id), [STUDIO_A, XDR, STUDIO_B, "ddc:HDMI-A-1", "backlight:intel_backlight"], "the flyout's own screen first");
  same(logic.parseSetRequest(JSON.stringify({ id: XDR, percent: 140, osd: true })), { ok: true, id: XDR, percent: 100, osd: true });
  same(logic.parseSetRequest(JSON.stringify({ id: XDR, percent: "60" })), { ok: false, error: "refused: set=shape want={id,percent,osd?}" });

  // --- Status ----------------------------------------------------------------
  let waiting = logic.queueSet(logic.emptyRuns(), XDR, 80);
  assert.equal(logic.displaysValue(resolved, waiting)[0].percent, 80, "a display shows the level waiting for it");
  const steps = { "apple-displays": { state: "needed", reason: "hidraw-denied" }, "i2c-dev": { state: "denied", reason: "no-uaccess-rule" } };
  const values = logic.statusValues(resolved, listed.backends, logic.emptyRuns(), steps, ["ddcutil"], null, "ready");
  same(Object.keys(values), ["displays", "assignments", "appleAccess", "ddcAccess", "ddcTool", "backlightTool"]);
  same(values.displays.state, "ready");
  same(values.displays.items[1], { id: STUDIO_A, device: KEY_A, label: "Apple Studio Display", backend: "hidraw", state: "ready", percent: 30, outputs: ["DP-2"], assigned: true });
  same(values.assignments, { entries: resolved.assignments, error: null });
  same(values.appleAccess, { tone: "warning", text: "Needs your permission", action: true });
  same(values.ddcAccess, { tone: "danger", text: "DDC access isn't supported on this system", action: false });
  same(values.ddcTool, { tone: "warning", text: "Not installed", action: true });
  same(values.backlightTool, { tone: "ok", text: "Installed", action: false });
  const unread = logic.statusValues(null, null, logic.emptyRuns(), null, ["brightnessctl"], "refused: assignments=unparsed", "failed");
  same([unread.displays, unread.assignments.error, unread.appleAccess.text, unread.backlightTool], [{ state: "failed", items: [] }, "refused: assignments=unparsed",
    "Access could not be checked", { tone: "info", text: "Not needed", action: false }]);
  same(logic.statusWrites({ displays: values.displays, ddcTool: { tone: "ok", text: "Installed", action: false } }, values).map(w => w.key),
    ["assignments", "appleAccess", "ddcAccess", "ddcTool", "backlightTool"], "only changed values are written");
  const ddc = shown[3];
  same(logic.displayAction(ddc, { ddcAccess: { tone: "warning", text: "", action: true } }), { key: "ddcAccess", label: "Allow" });
  same(logic.displayAction(ddc, { ddcAccess: { tone: "danger", text: "", action: false } }), null, "Allow shows only while the entry offers it");
  same(logic.displayAction(shown[0], values), null, "a ready display needs no Allow");
  assert.equal(logic.stateText("no-access"), "Needs your permission");
  assert.equal(logic.clampPercent(0), 1);
  assert.equal(logic.clampPercent(NaN), null);
}

verify(load(file));

const CONTROLS = [
  ["no coalescing: each change waits as its own run", "            next.sets[i].percent = percent;\n            return next;", "            break;"],
  ["a waiting list goes before the changes", "    if (next.sets.length > 0) {", "    if (next.sets.length > 0 && !next.list) {"],
  ["a second run starts while one is in flight", "    if (runs.busy !== null) return { runs: runs, run: null };", ""],
  ["the key ignores the focused output", "        if (displays[i].state === \"ready\" && displays[i].outputs.indexOf(name) !== -1) return displays[i];", "        if (displays[i].state === \"ready\") return displays[i];"],
  ["no fine steps at the dark end", "    var size = fine ? 1 : step;", "    var size = step;"],
  ["linked displays take the level, not the delta", "changes.push({ id: d.id, percent: clampPercent(d.percent + delta) });", "changes.push({ id: d.id, percent: wanted });"],
  ["a stale entry whose output is gone applies", "if (display === null || !hasOwn(byIdentifier, e.output)) {", "if (display === null) {"],
  ["an entry places a display the helper placed", "} else if (display.outputs.length > 0 || byIdentifier", "} else if (byIdentifier"],
  ["the judge takes one device twice", "if (hasOwn(devices, e.device)) return", "if (false) return"],
  ["a new choice drops stale entries", "return e.device !== device && !(e.output === output && present.indexOf(e.device) !== -1);", "return e.device !== device && e.output !== output;"],
  ["a level of 0 turns a panel off", "return Math.max(MIN_PERCENT, Math.min(MAX_PERCENT, Math.round(value)));", "return Math.max(0, Math.min(MAX_PERCENT, Math.round(value)));"],
  ["a needed step offers no Allow", "case \"needed\": return { tone: \"warning\", text: \"Needs your permission\", action: true };", "case \"needed\": return { tone: \"warning\", text: \"Needs your permission\", action: false };"]
];

const source = fs.readFileSync(file, "utf8");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "displays-logic-control-"));
try {
  for (const [label, needle, replacement] of CONTROLS) {
    assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
    const mutant = path.join(temp, "DisplaysLogic.js");
    fs.writeFileSync(mutant, source.replace(needle, () => replacement));
    let failed = false;
    try {
      verify(load(mutant));
    } catch (e) {
      failed = true;
    }
    assert.ok(failed, `control "${label}": the suite passed on the mutated logic`);
  }
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-displays-logic: ok controls=${CONTROLS.length}`);
