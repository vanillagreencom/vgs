.pragma library

// Pure decisions for vgs.displays: the brightness helper's answers judged,
// the order its runs go in, the assignments file judged and applied, what
// a brightness key, a scroll or a linked slider changes, and the status the
// service publishes and every surface reads. QML owns the processes, the
// files and the timers; helper/brightness.py owns the devices
// (docs/architecture/displays.md).

// A slider, a key and a scroll never go below 1 %: a kernel backlight at
// 0 % turns its panel off, as Omarchy's clampBrightness also holds.
var MIN_PERCENT = 1;
var MAX_PERCENT = 100;
// At the dark end a brightness key moves 1 % at a time: up from below
// this level and down from it or below, as Omarchy's
// omarchy-brightness-display does.
var FINE_STEP_AT = 5;
// A helper run is stopped after this long, as v1's brightness bridge did
// (backend/internal/services/brightnessbridge/brightnessbridge.go).
var HELPER_TIMEOUT_MS = 8000;
// Hotplug, an access change or an install lists again once this long has
// passed with no further change.
var RESCAN_DEBOUNCE_MS = 1000;
// How long Identify shows each screen's name and holds the display it
// flashes at its other level.
var IDENTIFY_MS = 3000;
// How long the on-screen display stays after the last change.
var OSD_MS = 1500;
// The assignments file holds at most this many entries; past it, the
// oldest entry of an absent device goes.
var ASSIGNMENTS_MAX = 64;
var ASSIGNMENT_TEXT_MAX = 512;

var BACKENDS = ["hidraw", "ddc", "backlight"];
var DISPLAY_STATES = ["ready", "no-access", "no-answer", "error", "unsupported"];
var BACKEND_STATES = ["ready", "missing", "module-not-loaded", "no-access", "error"];
var KEY_TARGETS = ["focused", "all"];
var ASSIGNMENT_KEYS = ["device", "label", "output"];
var STEP_STATES = ["ready", "needed", "denied", "absent", "unknown", "nixos"];

function hasOwn(object, key) {
    return object !== null && typeof object === "object" && Object.prototype.hasOwnProperty.call(object, key);
}

function isPlainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function clone(value) {
    return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

// VALUE as a refusal shows it: JSON, cut to 60 characters.
function shown(value) {
    var text = JSON.stringify(value);
    if (text === undefined) text = String(value);
    return text.length > 60 ? text.slice(0, 57) + "..." : text;
}

function parseJson(text, what) {
    try {
        return { ok: true, value: JSON.parse(text) };
    } catch (e) {
        return { ok: false, error: "refused: " + what + "=unparsed" };
    }
}

// VALUE as a whole percent from MIN_PERCENT to MAX_PERCENT, or null for a
// value that is not a finite number.
function clampPercent(value) {
    if (typeof value !== "number" || !isFinite(value)) return null;
    return Math.max(MIN_PERCENT, Math.min(MAX_PERCENT, Math.round(value)));
}

// --- The helper's answers ---------------------------------------------------

// The helper's `list` answer, judged: { ok: true, backends, displays } with
// each display { id, backend, label, state, percent, outputs, product,
// identity }, `product` and `identity` null for a display that has none,
// or { ok: false, error }. The shape is the helper header's.
function parseList(text) {
    var parsed = parseJson(text, "list");
    if (!parsed.ok) return parsed;
    var answer = parsed.value;
    if (!isPlainObject(answer)) return { ok: false, error: "refused: list=shape want=object" };
    if (hasOwn(answer, "error")) return { ok: false, error: "refused: list=helper error=" + shown(answer.error) };
    if (!isPlainObject(answer.backends)) return { ok: false, error: "refused: list=shape field=backends" };
    var backends = {};
    var names = ["ddc", "backlight"];
    for (var b = 0; b < names.length; b++) {
        var backend = answer.backends[names[b]];
        if (!isPlainObject(backend) || BACKEND_STATES.indexOf(backend.state) === -1)
            return { ok: false, error: "refused: list=shape backend=" + names[b] };
        backends[names[b]] = { state: backend.state };
    }
    if (!Array.isArray(answer.displays)) return { ok: false, error: "refused: list=shape field=displays" };
    var displays = [];
    var seen = {};
    for (var i = 0; i < answer.displays.length; i++) {
        var d = answer.displays[i];
        var bad = function (field) { return { ok: false, error: "refused: list=shape display=" + i + " field=" + field }; };
        if (!isPlainObject(d)) return bad("object");
        if (typeof d.id !== "string" || d.id === "" || hasOwn(seen, d.id)) return bad("id");
        if (BACKENDS.indexOf(d.backend) === -1) return bad("backend");
        if (typeof d.label !== "string" || d.label === "") return bad("label");
        if (DISPLAY_STATES.indexOf(d.state) === -1) return bad("state");
        if (d.state === "ready" ? !(Number.isInteger(d.percent) && d.percent >= 0 && d.percent <= 100) : d.percent !== null) return bad("percent");
        if (!Array.isArray(d.outputs) || d.outputs.some(function (o) { return typeof o !== "string" || o === ""; })) return bad("outputs");
        var identity = null;
        if (hasOwn(d, "identity")) {
            if (!isPlainObject(d.identity) || typeof d.identity.parent !== "string" || d.identity.parent === "" || typeof d.identity.serial !== "string")
                return bad("identity");
            identity = { parent: d.identity.parent, serial: d.identity.serial };
        }
        seen[d.id] = true;
        displays.push({
            id: d.id, backend: d.backend, label: d.label, state: d.state, percent: d.percent,
            outputs: d.outputs.slice(), product: typeof d.product === "string" ? d.product : null, identity: identity
        });
    }
    return { ok: true, backends: backends, displays: displays };
}

// The helper's `set` answer for ID, judged: { ok: true, percent } or
// { ok: false, error }, the helper's own failure named by its key and, for
// a display that is not ready, its state.
function parseSet(text, id) {
    var parsed = parseJson(text, "set");
    if (!parsed.ok) return parsed;
    var answer = parsed.value;
    if (!isPlainObject(answer)) return { ok: false, error: "refused: set=shape want=object" };
    if (hasOwn(answer, "error"))
        return { ok: false, error: "refused: set=helper error=" + shown(answer.error) + (hasOwn(answer, "state") ? " state=" + shown(answer.state) : "") };
    if (answer.id !== id || !Number.isInteger(answer.percent) || answer.percent < 0 || answer.percent > 100)
        return { ok: false, error: "refused: set=shape id=" + shown(answer.id) + " percent=" + shown(answer.percent) };
    return { ok: true, percent: answer.percent };
}

// --- Runs ----------------------------------------------------------------------

// The helper's runs, one at a time: { busy, sets, list }. `busy` is the
// run in flight or null; `sets` holds at most one { id, percent } per
// display, the latest asked for, in the order each display was first
// asked; `list` is whether a list waits. Sets go before a waiting list.
function emptyRuns() {
    return { busy: null, sets: [], list: false };
}

// RUNS with ID's next value PERCENT: a later value replaces the waiting
// one in its place, so a drag of any length makes at most the run in
// flight and one more per display.
function queueSet(runs, id, percent) {
    var next = clone(runs);
    for (var i = 0; i < next.sets.length; i++) {
        if (next.sets[i].id === id) {
            next.sets[i].percent = percent;
            return next;
        }
    }
    next.sets.push({ id: id, percent: percent });
    return next;
}

function queueList(runs) {
    var next = clone(runs);
    next.list = true;
    return next;
}

// { runs, run }: the run to start now, { verb: "set", id, percent } or
// { verb: "list" }, marked busy in RUNS, or null while one is in flight or
// nothing waits.
function takeRun(runs) {
    if (runs.busy !== null) return { runs: runs, run: null };
    var next = clone(runs);
    var run = null;
    if (next.sets.length > 0) {
        var set = next.sets.shift();
        run = { verb: "set", id: set.id, percent: set.percent };
    } else if (next.list) {
        next.list = false;
        run = { verb: "list" };
    }
    next.busy = run;
    return { runs: next, run: run };
}

function endRun(runs) {
    if (runs.busy === null) throw new Error("displays: endRun with no run in flight");
    var next = clone(runs);
    next.busy = null;
    return next;
}

// The value ID shows while its runs are not done: the waiting value, else
// the one in flight, else null.
function pendingPercent(runs, id) {
    for (var i = 0; i < runs.sets.length; i++)
        if (runs.sets[i].id === id) return runs.sets[i].percent;
    if (runs.busy !== null && runs.busy.verb === "set" && runs.busy.id === id) return runs.busy.percent;
    return null;
}

// --- Assignments ------------------------------------------------------------

// The key an assignment keeps a display under: its USB parent and serial
// for an Apple display, which tells two units of one product apart, else
// its id. A unit plugged into another port reads as a new device.
function deviceKey(display) {
    if (display.identity !== null) return "usb:" + display.identity.parent + "#" + display.identity.serial;
    return display.id;
}

function isText(value) {
    return typeof value === "string" && value !== "" && value.length <= ASSIGNMENT_TEXT_MAX && !/[\u0000-\u001f\u007f]/.test(value);
}

// The assignments file, judged: { ok: true, entries } with each entry
// { device, label, output }, `device` a deviceKey and `output` an output
// identifier as the monitors capability names it, or { ok: false, error }.
// At most one entry names a device.
function parseAssignments(text) {
    var parsed = parseJson(text, "assignments");
    if (!parsed.ok) return parsed;
    var doc = parsed.value;
    if (!isPlainObject(doc) || Object.keys(doc).length !== 1 || !Array.isArray(doc.assignments))
        return { ok: false, error: "refused: assignments=shape want={\"assignments\":[...]}" };
    if (doc.assignments.length > ASSIGNMENTS_MAX)
        return { ok: false, error: "refused: assignments=too-many count=" + doc.assignments.length + " max=" + ASSIGNMENTS_MAX };
    var entries = [];
    var devices = {};
    for (var i = 0; i < doc.assignments.length; i++) {
        var e = doc.assignments[i];
        var at = "refused: assignment=" + i + " ";
        if (!isPlainObject(e)) return { ok: false, error: at + "want=object" };
        var keys = Object.keys(e).sort();
        if (keys.join(",") !== ASSIGNMENT_KEYS.join(",")) return { ok: false, error: at + "keys=" + shown(keys) + " want=" + ASSIGNMENT_KEYS.join(",") };
        for (var k = 0; k < ASSIGNMENT_KEYS.length; k++)
            if (!isText(e[ASSIGNMENT_KEYS[k]])) return { ok: false, error: at + ASSIGNMENT_KEYS[k] + "=" + shown(e[ASSIGNMENT_KEYS[k]]) };
        if (hasOwn(devices, e.device)) return { ok: false, error: at + "device=" + shown(e.device) + " reason=repeated" };
        devices[e.device] = true;
        entries.push({ device: e.device, label: e.label, output: e.output });
    }
    return { ok: true, entries: entries };
}

function assignmentsText(entries) {
    return JSON.stringify({ assignments: entries }, null, 2) + "\n";
}

// OUTPUTS, the monitors capability's list, as one group per output
// identifier in the order each was first seen: [{ identifier, names,
// product }], NAMES every output of that identifier (a tiled Pro Display
// XDR has two) and PRODUCT the first one's make and model.
function outputGroups(outputs) {
    var groups = [];
    outputs.forEach(function (o) {
        var group = groupOf(groups, o.identifier);
        if (group === null) groups.push({ identifier: o.identifier, names: [o.name], product: (o.make + " " + o.model).trim() });
        else group.names.push(o.name);
    });
    return groups;
}

function groupOf(groups, identifier) {
    for (var g = 0; g < groups.length; g++) if (groups[g].identifier === identifier) return groups[g];
    return null;
}

// LISTED, the helper's displays, with the assignments ENTRIES applied over
// OUTPUTS, the monitors capability's list: { displays, assignments }.
// Each display gains `device`, its deviceKey, and `assigned`, whether an
// entry gave it its outputs. An entry applies only to a display the helper
// left unassigned, and only while its device and its output are both
// present and no other display lights that output; each entry is
// reported { device, label, output, state }, `state` `applied`, `stale`
// (its device or its output is gone; kept, never applied) or `unused`.
function resolve(listed, outputs, entries) {
    var groups = outputGroups(outputs);
    var displays = listed.map(function (d) {
        var out = clone(d);
        out.device = deviceKey(d);
        out.assigned = false;
        return out;
    });
    var lit = {};
    displays.forEach(function (d) { d.outputs.forEach(function (name) { lit[name] = true; }); });
    var reported = entries.map(function (e) {
        var display = null;
        for (var i = 0; i < displays.length; i++) if (displays[i].device === e.device) display = displays[i];
        var group = groupOf(groups, e.output);
        var state;
        if (display === null || group === null) {
            state = "stale";
        } else if (display.outputs.length > 0 || group.names.some(function (name) { return lit[name] === true; })) {
            state = "unused";
        } else {
            display.outputs = group.names.slice();
            display.assigned = true;
            display.outputs.forEach(function (name) { lit[name] = true; });
            state = "applied";
        }
        return { device: e.device, label: e.label, output: e.output, state: state };
    });
    return { displays: displays, assignments: reported };
}

// Whether the pane offers DISPLAY a Screen choice and Identify: the helper
// left it unplaced, or a user's choice placed it.
function placeable(display) {
    return display.outputs.length === 0 || display.assigned;
}

// The Screen choices for DISPLAYS, as resolve or the `displays` status
// lists them, over OUTPUTS: no choice first, then one { label, value } per
// output identifier that no display the helper placed lights, VALUE the
// identifier an assignment names and LABEL its outputs' names and product.
// An output a user's choice lit stays, since a new choice there moves it
// (setAssignment); the service's `assign` refuses any other identifier.
function screenChoices(displays, outputs) {
    var helperLit = {};
    displays.forEach(function (d) {
        if (!d.assigned) d.outputs.forEach(function (name) { helperLit[name] = true; });
    });
    var choices = [{ label: "Choose a screen", value: "" }];
    outputGroups(outputs).forEach(function (g) {
        if (g.names.some(function (name) { return helperLit[name] === true; })) return;
        choices.push({ label: g.names.join(" + ") + (g.product === "" ? "" : ": " + g.product), value: g.identifier });
    });
    return choices;
}

// ENTRIES with DEVICE, labelled LABEL, put on output identifier OUTPUT: the
// device's own entry replaced, and the entry of any other device in
// PRESENT, the device keys the helper lists now, that names the same output
// dropped, since one output shows one display. Stale entries stay; past
// ASSIGNMENTS_MAX the oldest entry whose device is not present goes.
function setAssignment(entries, device, label, output, present) {
    var next = entries.filter(function (e) {
        return e.device !== device && !(e.output === output && present.indexOf(e.device) !== -1);
    });
    next.push({ device: device, label: label, output: output });
    while (next.length > ASSIGNMENTS_MAX) {
        var gone = -1;
        for (var i = 0; i < next.length && gone === -1; i++) if (present.indexOf(next[i].device) === -1) gone = i;
        if (gone === -1) throw new Error("displays: " + next.length + " assignments name present devices, more than " + ASSIGNMENTS_MAX);
        next.splice(gone, 1);
    }
    return next;
}

function clearAssignment(entries, device) {
    return entries.filter(function (e) { return e.device !== device; });
}

// The request an instance hands the service's `assign` handler, judged:
// { ok: true, device, output } with OUTPUT "" to clear, or { ok: false,
// error }.
function parseAssignRequest(text) {
    var parsed = parseJson(text, "assign");
    if (!parsed.ok) return parsed;
    var r = parsed.value;
    if (!isPlainObject(r) || !isText(r.device) || typeof r.output !== "string" || (r.output !== "" && !isText(r.output)))
        return { ok: false, error: "refused: assign=shape want={device,output}" };
    return { ok: true, device: r.device, output: r.output };
}

// --- Changes ------------------------------------------------------------------

// The ready display of DISPLAYS whose outputs include NAME, or null.
function displayOn(displays, name) {
    for (var i = 0; i < displays.length; i++)
        if (displays[i].state === "ready" && displays[i].outputs.indexOf(name) !== -1) return displays[i];
    return null;
}

function displayById(displays, id) {
    for (var i = 0; i < displays.length; i++) if (displays[i].id === id) return displays[i];
    return null;
}

// What setting display ID to PERCENT changes: [{ id, percent }], ID first.
// While LINKED, every other ready display moves by the same amount, each
// held to MIN_PERCENT..MAX_PERCENT. A display that is not ready changes
// nothing.
function linkedChanges(displays, id, percent, linked) {
    var target = displayById(displays, id);
    var wanted = clampPercent(percent);
    if (target === null || target.state !== "ready" || wanted === null) return [];
    var changes = [{ id: id, percent: wanted }];
    if (!linked) return changes;
    var delta = wanted - target.percent;
    displays.forEach(function (d) {
        if (d.id !== id && d.state === "ready") changes.push({ id: d.id, percent: clampPercent(d.percent + delta) });
    });
    return changes;
}

// The level a brightness key moves CURRENT to: STEP up or down, but 1 at a
// time at the dark end (FINE_STEP_AT), held to MIN_PERCENT..MAX_PERCENT.
function keyStep(current, direction, step) {
    if (direction !== "up" && direction !== "down") throw new Error("displays: key direction " + JSON.stringify(direction) + " is not up or down");
    var fine = direction === "up" ? current < FINE_STEP_AT : current <= FINE_STEP_AT;
    var size = fine ? 1 : step;
    return clampPercent(current + (direction === "up" ? size : -size));
}

// What a brightness key in DIRECTION changes: [{ id, percent }]. TARGET
// `focused` moves the ready display on FOCUSED, the output Hyprland
// focuses, and, while LINKED, every other ready display by as much; `all`
// moves every ready display by its own step, the one on FOCUSED first, so
// the on-screen display shows on the focused screen. No ready display there
// changes nothing.
function keyChanges(displays, focused, target, direction, step, linked) {
    if (KEY_TARGETS.indexOf(target) === -1) throw new Error("displays: keysTarget " + JSON.stringify(target) + " is not one of " + KEY_TARGETS.join(", "));
    if (target === "all") {
        return panelOrder(displays, focused).filter(function (d) { return d.state === "ready"; })
            .map(function (d) { return { id: d.id, percent: keyStep(d.percent, direction, step) }; });
    }
    var display = displayOn(displays, focused);
    if (display === null) return [];
    return linkedChanges(displays, display.id, keyStep(display.percent, direction, step), linked);
}

// The level NOTCHES of a scroll move CURRENT to, STEP a notch, up for a
// positive count.
function scrollTarget(current, notches, step) {
    return clampPercent(current + notches * step);
}

// DISPLAYS for a flyout on screen NAME: the display on that screen first,
// then the rest in the helper's order.
function panelOrder(displays, name) {
    var own = displays.filter(function (d) { return d.outputs.indexOf(name) !== -1; });
    return own.concat(displays.filter(function (d) { return d.outputs.indexOf(name) === -1; }));
}

// The request an instance hands the service's `set` handler, judged:
// { ok: true, id, percent, osd } or { ok: false, error }.
function parseSetRequest(text) {
    var parsed = parseJson(text, "set");
    if (!parsed.ok) return parsed;
    var r = parsed.value;
    if (!isPlainObject(r) || typeof r.id !== "string" || r.id === "" || clampPercent(r.percent) === null || (hasOwn(r, "osd") && typeof r.osd !== "boolean"))
        return { ok: false, error: "refused: set=shape want={id,percent,osd?}" };
    return { ok: true, id: r.id, percent: clampPercent(r.percent), osd: r.osd === true };
}

// --- Status ---------------------------------------------------------------------

// The `displays` value: every display as the surfaces draw it, its percent
// the one waiting in RUNS while a change is in flight.
function displaysValue(resolved, runs) {
    return resolved.displays.map(function (d) {
        var pending = pendingPercent(runs, d.id);
        return {
            id: d.id, device: d.device, label: d.label, backend: d.backend, state: d.state,
            percent: d.state === "ready" ? (pending !== null ? pending : d.percent) : null,
            outputs: d.outputs.slice(), assigned: d.assigned
        };
    });
}

// A system step's reading as the `state` value of its access entry: TEXTS
// names the sentence for `absent` and `denied`, which differ per step.
function stepState(step, texts) {
    var state = step === null || step === undefined ? "unknown" : step.state;
    switch (state) {
    case "ready": return { tone: "ok", text: "Allowed", action: false };
    case "needed": return { tone: "warning", text: "Needs your permission", action: true };
    case "nixos": return { tone: "warning", text: "Needs your NixOS configuration", action: true };
    case "absent": return { tone: "info", text: texts.absent, action: false };
    case "denied": return { tone: "danger", text: texts.denied, action: false };
    case "unknown": return { tone: "warning", text: "Access could not be checked", action: false };
    }
    throw new Error("displays: step state " + JSON.stringify(state) + " is not one of " + STEP_STATES.join(", "));
}

// An optional command's entry: Install is offered while MISSING, the
// requirement capability's list, names COMMAND and NEEDED holds, that is
// while a display could use it.
function toolState(missing, command, needed) {
    if (missing.indexOf(command) === -1) return { tone: "ok", text: "Installed", action: false };
    if (!needed) return { tone: "info", text: "Not needed", action: false };
    return { tone: "warning", text: "Not installed", action: true };
}

// Every status value the service publishes. RESOLVED is the helper's last
// list with the assignments applied, null before the first list or while
// the outputs are unread; BACKENDS its backend states; RUNS the helper's
// runs; STEPS the system steps' states, null before the first probe;
// MISSING the plugin's commands the last scan did not find;
// ASSIGNMENTSERROR the assignments file's keyed refusal or null; and
// LISTSTATE `pending`, `ready` or `failed`, the last list's outcome.
// `displays` is { state, items }; `assignments` is { entries, error }.
function statusValues(resolved, backends, runs, steps, missing, assignmentsError, listState) {
    return {
        displays: { state: listState, items: resolved === null ? [] : displaysValue(resolved, runs) },
        assignments: { entries: resolved === null ? [] : resolved.assignments, error: assignmentsError },
        appleAccess: stepState(steps === null ? null : steps["apple-displays"], {
            absent: "No Apple display connected",
            denied: "Apple display access is blocked on this system"
        }),
        ddcAccess: stepState(steps === null ? null : steps["i2c-dev"], {
            absent: "No external display connected",
            denied: "DDC access isn't supported on this system"
        }),
        ddcTool: toolState(missing, "ddcutil", true),
        backlightTool: toolState(missing, "brightnessctl", backends !== null && backends.backlight.state === "missing")
    };
}

// The status writes that bring REPORTED, the values last written, to
// VALUES: [{ key, value }] for each key whose value changed.
function statusWrites(reported, values) {
    var out = [];
    Object.keys(values).forEach(function (key) {
        if (!hasOwn(reported, key) || JSON.stringify(reported[key]) !== JSON.stringify(values[key])) out.push({ key: key, value: values[key] });
    });
    return out;
}

// The sentence a surface shows for a display that is not ready.
function stateText(state) {
    switch (state) {
    case "ready": return "";
    case "no-access": return "Needs your permission";
    case "no-answer": return "Not responding";
    case "error": return "Could not be read";
    case "unsupported": return "Brightness control isn't supported";
    }
    throw new Error("displays: display state " + JSON.stringify(state) + " is not one of " + DISPLAY_STATES.join(", "));
}

// The status entry whose action makes DISPLAY ready: the access entry of
// its backend for a display the user may not open, else null. The manifest
// declares no access entry for a backlight. Whether the entry offers its
// action, and its label, are the core's status rows' (`status.rows`).
function accessKey(display) {
    if (display.state !== "no-access") return null;
    switch (display.backend) {
    case "hidraw": return "appleAccess";
    case "ddc": return "ddcAccess";
    case "backlight": return null;
    }
    throw new Error("displays: backend " + JSON.stringify(display.backend) + " is not one of " + BACKENDS.join(", "));
}

// The line the flyout and the pane show for the `displays` status: STATE
// its list state and COUNT its items, "" for none. A failed list keeps the
// last good items, so the line says they may be out of date.
function listText(state, count) {
    switch (state) {
    case "pending": return count === 0 ? "Reading displays" : "";
    case "ready": return count === 0 ? "No display with brightness control" : "";
    case "failed": return count === 0 ? "Displays could not be read." : "Displays could not be read again, so these may be out of date.";
    }
    throw new Error("displays: list state " + JSON.stringify(state) + " is not one of pending, ready, failed");
}

// The Saved choices sentence for ERROR, the `assignments` status's keyed
// refusal or null. A write failure leaves the choice in force until VGS
// restarts; any other refusal is a file the service did not read.
function savedChoicesText(error) {
    if (error === null) return "These displays or screens are not connected now.";
    if (error.indexOf("refused: assignments=unwritten ") === 0) return "Your choice could not be saved and will be lost when VGS restarts.";
    return "The saved choices could not be read. Your next choice replaces them.";
}

// The line a surface shows for REPLY, an answer from the service or the
// core: "" for `ok`, else a plain sentence; the reply itself goes to the
// log.
function replyText(reply) {
    if (reply === "ok") return "";
    return "That did not work. Try again.";
}
