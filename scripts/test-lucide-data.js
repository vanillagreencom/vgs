#!/usr/bin/env node
// The generated icon data, shell/Ui/icons/Lucide.js: every path parses as SVG
// path commands, the count meets a floor, the names the components draw
// exist, and the version is the pinned one. The controls at the end plant one
// defect per rule in a copy of the data and require this suite to fail on it.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("./qml-library.js");

const dataFile = path.join(__dirname, "..", "shell", "Ui", "icons", "Lucide.js");
const PINNED_VERSION = "1.48.0";
// Below this the generator walked a partial package; 1.48.0 holds 1854.
const COUNT_FLOOR = 1800;
// The names first-party components and the shipped bar draw.
const REQUIRED = ["check", "chevron-down", "chevron-right", "chevron-up", "x", "search", "circle", "info", "triangle-alert", "circle-check", "circle-x", "loader-circle", "minus", "plus", "eye", "eye-off", "settings", "square", "palette"];

// One SVG path by its grammar: each command takes a whole number of its
// argument groups (a move or line a pair, a cubic six, an arc seven with
// two one-digit flags, a close none), so a coordinate split in the wrong
// place, such as `16.36.8` read as one number, leaves a group short and
// refuses.
const ARITY = { M: 2, L: 2, T: 2, H: 1, V: 1, C: 6, S: 4, Q: 4, A: 7, Z: 0 };
const NUMBER = /^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?/;
function parsePath(d) {
    let i = 0;
    let commands = 0;
    let command = null;
    let args = 0;
    const settle = () => command === null || (ARITY[command] === 0 ? args === 0 : args > 0 && args % ARITY[command] === 0);
    while (i < d.length) {
        const c = d[i];
        if (c === " " || c === "," || c === "\n") { i++; continue; }
        const upper = c.toUpperCase();
        if (Object.prototype.hasOwnProperty.call(ARITY, upper)) {
            if (!settle()) return { ok: false, at: i, char: c };
            command = upper;
            args = 0;
            commands++;
            i++;
            continue;
        }
        if (command === null || ARITY[command] === 0) return { ok: false, at: i, char: c };
        // An arc's two flags are single digits and may touch the next number.
        if (command === "A" && (args % 7 === 3 || args % 7 === 4)) {
            if (c !== "0" && c !== "1") return { ok: false, at: i, char: c };
            args++;
            i++;
            continue;
        }
        const m = NUMBER.exec(d.slice(i));
        if (m === null) return { ok: false, at: i, char: c };
        args++;
        i += m[0].length;
    }
    if (!settle()) return { ok: false, at: i, char: "end" };
    return { ok: true, commands };
}

function verify(data) {
    assert.equal(data.VERSION, PINNED_VERSION);
    assert.equal(data.VIEWBOX, 24);
    const names = Object.keys(data.ICONS);
    assert.ok(names.length >= COUNT_FLOOR, `${names.length} icons; the generator walked a partial package`);
    for (const name of REQUIRED)
        assert.ok(Object.prototype.hasOwnProperty.call(data.ICONS, name), `required icon ${name} is absent`);
    for (const name of names) {
        const entry = data.ICONS[name];
        assert.ok(Array.isArray(entry) && entry.length === 2 && entry.every(d => typeof d === "string"), `${name}: not a [stroke, fill] pair`);
        assert.match(name, /^[a-z0-9]+(-[a-z0-9]+)*$/, name);
        const stroke = parsePath(entry[0]);
        assert.ok(stroke.ok, `${name}: stroke path does not parse at ${stroke.at}: ${JSON.stringify(stroke.char)}`);
        assert.ok(stroke.commands > 0 || entry[1] !== "", `${name}: draws nothing`);
        const fill = parsePath(entry[1]);
        assert.ok(fill.ok, `${name}: fill path does not parse at ${fill.at}`);
        assert.match(entry[0], /^(?:[Mm]|$)/, `${name}: a path starts with a move`);
    }
    // Converted primitives: a circle is two arcs, a plain rect four lines.
    assert.equal(data.ICONS.circle[0], "M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0z");
    assert.equal(data.ICONS.square[0], "M5 3h14a2 2 0 0 1 2 2v14a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-14a2 2 0 0 1 2 -2z");
    assert.equal(data.ICONS.minus[0], "M5 12h14");
    // A second element's leading relative move is absolute once joined.
    assert.equal(data.ICONS.x[0], "M18 6 6 18 M6 6 l12 12");
    assert.equal(data.ICONS["check-check"][0], "M18 6 7 17l-5-5 M22 10 l-7.5 7.5L13 16");
    // A leading move written with compact decimals, `m7.88 16.36.8 4`, is
    // two numbers then a pair.
    assert.ok(data.ICONS.watch[0].indexOf("M7.88 16.36 l.8 4") !== -1, "compact decimals split by the grammar: " + data.ICONS.watch[0]);
    for (const name of names)
        for (const d of data.ICONS[name])
            assert.ok(!/(^|\s)m/.test(d.replace(/^m/, "")), `${name}: a joined path starts with a relative move`);
    assert.ok(data.ICONS.palette[1].startsWith("M13 6.5a0.5 0.5 0 1 0 1 0"), "a filled circle lands in the fill path");
}
verify(load(dataFile));

// Each control plants one defect in a copy of the data.
const CONTROLS = [
    ["version", 'var VERSION = "1.48.0";', 'var VERSION = "1.47.0";'],
    ["viewbox", "var VIEWBOX = 24;", "var VIEWBOX = 16;"],
    ["a malformed path", '"check": ["M20 6 9 17l-5-5",""]', '"check": ["M20 6 9 17l-5-5 x",""]'],
    ["a missing required name", '"check": ["M20 6 9 17l-5-5",""]', '"chekc": ["M20 6 9 17l-5-5",""]'],
    ["a joined path starting with a relative move", '"x": ["M18 6 6 18 M6 6 l12 12",""]', '"x": ["M18 6 6 18 m6 6 12 12",""]'],
    ["a move's implicit lines made absolute", '"x": ["M18 6 6 18 M6 6 l12 12",""]', '"x": ["M18 6 6 18 M6 6 12 12",""]'],
    ["compact decimals read as one number", "M7.88 16.36 l.8 4", "M7.88 16.36.8 l4"],
    ["a wrong circle conversion", '"circle": ["M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0z",""]', '"circle": ["M2 12a10 10 0 1 0 20 0z",""]'],
    ["a fill lost to the stroke path", '2.8z","M13 6.5a0.5 0.5 0 1 0 1 0a0.5 0.5 0 1 0 -1 0z M17', '2.8z M13 6.5a0.5 0.5 0 1 0 1 0a0.5 0.5 0 1 0 -1 0z","M17']
];
const source = fs.readFileSync(dataFile, "utf8");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "lucide-data-control-"));
try {
    for (const [label, needle, replacement] of CONTROLS) {
        assert.equal(source.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutant = path.join(temp, "Lucide.js");
        fs.writeFileSync(mutant, source.replace(needle, () => replacement));
        let failed = false;
        try {
            verify(load(mutant));
        } catch (e) {
            failed = true;
        }
        assert.ok(failed, `control "${label}": the suite passed on data with that defect`);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log(`test-lucide-data: ok icons=${Object.keys(load(dataFile).ICONS).length} controls=${CONTROLS.length}`);
