// The one reader of bin/vgsh's preflight_floor table for the checks under
// scripts/: check-packaging.js and check-readme.js.
//
// parseFloors(text) takes bin/vgsh's text and returns one tagged value:
//   { ok: true, rows: [{ tool, need, probe }] }: need a dotted version or
//     `present`, probe the first word of the probe command;
//   { ok: false, key, detail }: key `floors=unreadable` for no table or a
//     malformed row, `floors=empty` for a table with no row.
// The table is the lines between `preflight_floor='` and the closing `'`.
// DOTTED is the version form bin/vgsh's version_at_least compares.
"use strict";

const DOTTED = /^[0-9]+(\.[0-9]+)*$/;

function parseFloors(text) {
    const block = /^preflight_floor='\n([\s\S]*?)^'$/m.exec(text);
    if (block === null) return { ok: false, key: "floors=unreadable", detail: "no preflight_floor='...' table" };
    const rows = [];
    for (const line of block[1].split("\n")) {
        if (line.trim() === "") continue;
        const fields = line.trim().split(/\s+/);
        if (fields.length < 4 || (fields[1] !== "present" && !DOTTED.test(fields[1])))
            return { ok: false, key: "floors=unreadable", detail: "row: " + line };
        rows.push({ tool: fields[0], need: fields[1], probe: fields[3] });
    }
    if (rows.length === 0) return { ok: false, key: "floors=empty", detail: "the table always has rows, so the reader is broken" };
    return { ok: true, rows };
}

module.exports = { parseFloors, DOTTED };
