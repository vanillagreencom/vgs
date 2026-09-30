#!/usr/bin/env node
// The painted-extent reader, shell/Ui/foundation/IconBounds.js, under node:
// over every Lucide icon it answers a finite box, and that box holds every
// point of the icon's outline, sampled by an independent reader of the SVG
// path grammar (SVG 1.1 § 8.3 and F.6) at 64 points per curve and arc.
// Hand-worked cases pin an arc's real extent, packed arc flags and the
// reflected control point of S and T.
//
// The controls at the end edit a copy of the reader, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const file = path.join(__dirname, "..", "shell", "Ui", "foundation", "IconBounds.js");
const lucide = load(path.join(__dirname, "..", "shell", "Ui", "icons", "Lucide.js"));
const STEPS = 64;
const EPSILON = 1e-6;

// The outline of DATA as sampled points. Its own scanner reads a flag as
// one 0 or 1 character, as the grammar states.
function outline(data) {
    const text = String(data);
    let at = 0;
    const skip = () => { while (at < text.length && /[\s,]/.test(text[at])) at++; };
    const num = () => {
        skip();
        const match = /^-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/.exec(text.slice(at));
        if (!match) throw new Error("number at " + at + " in " + text);
        at += match[0].length;
        return Number(match[0]);
    };
    const flag = () => { skip(); const c = text[at++]; if (c !== "0" && c !== "1") throw new Error("flag at " + at); return c === "1"; };
    const numberNext = () => { skip(); return at < text.length && /[-.\d]/.test(text[at]); };
    const points = [];
    let x = 0, y = 0, sx = 0, sy = 0, cmd = "", lastCtrl = null, lastKind = "";
    const cubic = (x0, y0, x1, y1, x2, y2, x3, y3) => {
        for (let i = 0; i <= STEPS; i++) {
            const t = i / STEPS, u = 1 - t;
            points.push([u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3, u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3]);
        }
    };
    const quad = (x0, y0, x1, y1, x2, y2) => {
        for (let i = 0; i <= STEPS; i++) {
            const t = i / STEPS, u = 1 - t;
            points.push([u * u * x0 + 2 * u * t * x1 + t * t * x2, u * u * y0 + 2 * u * t * y1 + t * t * y2]);
        }
    };
    const arc = (x1, y1, rx, ry, deg, fa, fs, x2, y2) => {
        if (rx === 0 || ry === 0) { points.push([x2, y2]); return; }
        rx = Math.abs(rx); ry = Math.abs(ry);
        const phi = deg * Math.PI / 180, c = Math.cos(phi), s = Math.sin(phi);
        const xp = c * (x1 - x2) / 2 + s * (y1 - y2) / 2, yp = -s * (x1 - x2) / 2 + c * (y1 - y2) / 2;
        const l = xp * xp / (rx * rx) + yp * yp / (ry * ry);
        if (l > 1) { rx *= Math.sqrt(l); ry *= Math.sqrt(l); }
        const k = (fa === fs ? -1 : 1) * Math.sqrt(Math.max(0, (rx * rx * ry * ry - rx * rx * yp * yp - ry * ry * xp * xp) / (rx * rx * yp * yp + ry * ry * xp * xp)));
        const cxp = k * rx * yp / ry, cyp = -k * ry * xp / rx;
        const cx = c * cxp - s * cyp + (x1 + x2) / 2, cy = s * cxp + c * cyp + (y1 + y2) / 2;
        const ang = (ux, uy, vx, vy) => Math.atan2(ux * vy - uy * vx, ux * vx + uy * vy);
        const t1 = ang(1, 0, (xp - cxp) / rx, (yp - cyp) / ry);
        let dt = ang((xp - cxp) / rx, (yp - cyp) / ry, (-xp - cxp) / rx, (-yp - cyp) / ry);
        if (!fs && dt > 0) dt -= 2 * Math.PI;
        if (fs && dt < 0) dt += 2 * Math.PI;
        for (let i = 0; i <= STEPS; i++) {
            const t = t1 + dt * i / STEPS;
            points.push([cx + rx * c * Math.cos(t) - ry * s * Math.sin(t), cy + rx * s * Math.cos(t) + ry * c * Math.sin(t)]);
        }
    };
    while (true) {
        skip();
        if (at >= text.length) break;
        if (!numberNext()) cmd = text[at++];
        const rel = cmd === cmd.toLowerCase(), ox = rel ? x : 0, oy = rel ? y : 0, kind = cmd.toUpperCase();
        let ctrl = null;
        if (kind === "M") { x = ox + num(); y = oy + num(); sx = x; sy = y; points.push([x, y]); cmd = rel ? "l" : "L"; }
        else if (kind === "L") { x = ox + num(); y = oy + num(); points.push([x, y]); }
        else if (kind === "H") { x = ox + num(); points.push([x, y]); }
        else if (kind === "V") { y = oy + num(); points.push([x, y]); }
        else if (kind === "Z") { x = sx; y = sy; cmd = ""; }
        else if (kind === "C" || kind === "S") {
            let x1, y1;
            if (kind === "C") { x1 = ox + num(); y1 = oy + num(); }
            else if (lastKind === "C" || lastKind === "S") { x1 = 2 * x - lastCtrl[0]; y1 = 2 * y - lastCtrl[1]; }
            else { x1 = x; y1 = y; }
            const x2 = ox + num(), y2 = oy + num(), x3 = ox + num(), y3 = oy + num();
            cubic(x, y, x1, y1, x2, y2, x3, y3);
            ctrl = [x2, y2]; x = x3; y = y3;
        } else if (kind === "Q" || kind === "T") {
            let x1, y1;
            if (kind === "Q") { x1 = ox + num(); y1 = oy + num(); }
            else if (lastKind === "Q" || lastKind === "T") { x1 = 2 * x - lastCtrl[0]; y1 = 2 * y - lastCtrl[1]; }
            else { x1 = x; y1 = y; }
            const x2 = ox + num(), y2 = oy + num();
            quad(x, y, x1, y1, x2, y2);
            ctrl = [x1, y1]; x = x2; y = y2;
        } else if (kind === "A") {
            const rx = num(), ry = num(), deg = num(), fa = flag(), fsw = flag(), x2 = ox + num(), y2 = oy + num();
            arc(x, y, rx, ry, deg, fa, fsw, x2, y2);
            x = x2; y = y2;
        } else throw new Error("command " + cmd);
        lastKind = ctrl ? kind : "";
        lastCtrl = ctrl;
    }
    return points;
}

function run(judgeFile) {
    const bounds = load(judgeFile).bounds;
    const same = (data, want, what) => {
        const box = bounds(data);
        for (const side of ["left", "top", "right", "bottom"]) assert.ok(Math.abs(box[side] - want[side]) < 1e-9, `${what}: ${side} ${box[side]}, want ${want[side]}`);
    };
    // The top half of a circle of radius 10 around (12, 12): only the arc
    // branch reaches its top at 2, and its bottom stays at the chord, 12.
    same("M2 12a10 10 0 0 1 20 0", { left: 2, top: 2, right: 22, bottom: 12 }, "a half circle");
    // The same half with its flags packed after the rotation, `0 01`.
    same("M2 12a10 10 0 0120 0", { left: 2, top: 2, right: 22, bottom: 12 }, "packed arc flags");
    // A whole circle in two arcs whose flags run together.
    same("M22 12a10 10 0 1 1-20 0 10 10 0 1 1 20 0", { left: 2, top: 2, right: 22, bottom: 22 }, "a circle in two arcs");
    // S after C reflects C's second control (4, 0) about (6, 2) to (8, 4).
    same("M0 2C0 0 4 0 6 2S10 2 10 2", { left: 0, top: 0, right: 10, bottom: 4 }, "S reflects the control before it");
    // T after Q reflects Q's control (2, 0) about (4, 2) to (6, 4).
    same("M0 2Q2 0 4 2T8 2", { left: 0, top: 0, right: 8, bottom: 4 }, "T reflects the control before it");

    let icons = 0;
    for (const [name, data] of Object.entries(lucide.ICONS)) {
        const joined = data[0] + " " + data[1];
        if (joined.trim() === "") continue;
        const box = bounds(joined);
        assert.ok(box !== null, name + ": no box");
        for (const side of ["left", "top", "right", "bottom"]) assert.ok(Number.isFinite(box[side]), `${name}: ${side} is ${box[side]}`);
        for (const [px, py] of outline(joined)) {
            assert.ok(px >= box.left - EPSILON && px <= box.right + EPSILON && py >= box.top - EPSILON && py <= box.bottom + EPSILON,
                `${name}: outline point (${px.toFixed(3)}, ${py.toFixed(3)}) outside ${JSON.stringify(box)}`);
        }
        icons++;
    }
    return icons;
}

function mutant(needle, replacement) {
    const text = fs.readFileSync(file, "utf8");
    assert.equal(text.split(needle).length - 1, 1, "control needle must occur once: " + needle);
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "icon-bounds-"));
    const copy = path.join(dir, "IconBounds.js");
    fs.writeFileSync(copy, text.replace(needle, replacement));
    return { copy, dir };
}

const icons = run(file);
const controls = [
    ["flags read as numbers", "var FLAG = /[\\s,]*([01])/y;", "var FLAG = NUMBER;"],
    ["an arc adds only its end", "        if (inside(theta)) pointAt(theta);", "        if (false) pointAt(theta);"],
    ["S reflects nothing", "            case \"S\":\n                add(reflectedX, reflectedY);", "            case \"S\":"],
    ["T reflects nothing", "                controlX = reflectedX; controlY = reflectedY;\n                add(controlX, controlY);", "                controlX = reflectedX; controlY = reflectedY;"],
];
for (const [label, needle, replacement] of controls) {
    const { copy, dir } = mutant(needle, replacement);
    let failed = false;
    try { run(copy); } catch (error) { failed = true; }
    fs.rmSync(dir, { recursive: true, force: true });
    assert.ok(failed, "control passed: " + label);
}
console.log(`test-icon-bounds: ok icons=${icons} controls=${controls.length}`);
