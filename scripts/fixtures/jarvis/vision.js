// Synthetic screens for the Jarvis vision executor, 2026-10-02. A world holds
// the stand-in hyprctl's state file in Hyprland v0.56.2's `-j` field names
// and the scene scripts/fixtures/jarvis/vision-tool.py draws as grim would.
// Each output's layout box in a scene is written by hand from the mode,
// scale and transform, never computed by the judge under test.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const zlib = require("node:zlib");

const BACKGROUND = [10, 20, 30];

function monitor(id, name, values) {
    return { id, name, focused: id === 0, activeWorkspace: { id: id + 1, name: String(id + 1) },
        specialWorkspace: { id: 0, name: "" }, x: 0, y: 0, transform: 0, ...values };
}

function client(address, values) {
    return { address, mapped: true, hidden: false, visible: true, workspace: { id: 1, name: "1" }, monitor: 0,
        floating: true, fullscreen: 0, class: "fixture.app", initialClass: "fixture.app", title: "Fixture " + address,
        initialTitle: "Fixture " + address, focusHistoryID: 0, ...values };
}

/**
 * world(runtime, root) owns one synthetic screen: set({monitors, clients,
 * outputs, colors}) writes the hyprctl state and grim's scene, modes(value)
 * the stand-ins' modes, calls() what they ran.
 */
function world(runtime, root) {
    const fixture = path.join(root, "vision-fixture");
    fs.mkdirSync(fixture, { recursive: true });
    const stateFile = path.join(runtime, "fixture-hyprland.json");
    const state = (monitors, clients) => ({ clients, active: clients.length ? clients[0].address : "", monitors,
        workspaces: monitors.map(m => ({ id: m.activeWorkspace.id, name: m.activeWorkspace.name, monitor: m.name, windows: 0 })) });
    return {
        fixture, stateFile, state,
        set({ monitors, clients, outputs, colors }, modes = {}) {
            for (const name of fs.readdirSync(fixture)) fs.rmSync(path.join(fixture, name), { recursive: true });
            for (const name of ["hyprctl.fail", "hyprctl.delay"]) fs.rmSync(path.join(runtime, name), { force: true });
            fs.writeFileSync(stateFile, JSON.stringify(state(monitors, clients)));
            fs.writeFileSync(path.join(fixture, "scene.json"), JSON.stringify({ outputs, colors, background: BACKGROUND }));
            fs.writeFileSync(path.join(fixture, "modes.json"), JSON.stringify(modes));
            fs.writeFileSync(path.join(fixture, "calls.jsonl"), "");
        },
        calls: () => fs.readFileSync(path.join(fixture, "calls.jsonl"), "utf8").split("\n").filter(Boolean).map(JSON.parse),
        locked: () => fs.existsSync(path.join(fixture, "locked")),
        lock: () => fs.writeFileSync(path.join(fixture, "locked"), ""),
        grim: count => JSON.parse(fs.readFileSync(path.join(fixture, "grim." + count + ".json"), "utf8"))
    };
}

/**
 * Decode an 8-bit RGBA PNG, the format grim's stand-in and `PNG32:` write:
 * {width, height, pixel(x, y) -> [r, g, b, a]}. Any other format throws.
 */
function decode(bytes) {
    if (!bytes.subarray(0, 8).equals(Buffer.from("89504e470d0a1a0a", "hex"))) throw new Error("png: signature");
    let offset = 8, width = 0, height = 0;
    const data = [];
    while (offset < bytes.length) {
        const length = bytes.readUInt32BE(offset);
        const kind = bytes.toString("latin1", offset + 4, offset + 8);
        const body = bytes.subarray(offset + 8, offset + 8 + length);
        if (kind === "IHDR") {
            width = body.readUInt32BE(0);
            height = body.readUInt32BE(4);
            if (body[8] !== 8 || body[9] !== 6 || body[12] !== 0) throw new Error("png: not 8-bit RGBA without interlace");
        } else if (kind === "IDAT") data.push(body);
        offset += 12 + length;
    }
    const raw = zlib.inflateSync(Buffer.concat(data));
    const stride = width * 4;
    const out = Buffer.alloc(stride * height);
    for (let y = 0; y < height; y++) {
        const filter = raw[y * (stride + 1)];
        const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
        for (let i = 0; i < stride; i++) {
            const left = i >= 4 ? out[y * stride + i - 4] : 0;
            const up = y > 0 ? out[(y - 1) * stride + i] : 0;
            const corner = i >= 4 && y > 0 ? out[(y - 1) * stride + i - 4] : 0;
            let value;
            switch (filter) {
            case 0: value = line[i]; break;
            case 1: value = line[i] + left; break;
            case 2: value = line[i] + up; break;
            case 3: value = line[i] + ((left + up) >> 1); break;
            case 4: {
                const p = left + up - corner, pa = Math.abs(p - left), pb = Math.abs(p - up), pc = Math.abs(p - corner);
                value = line[i] + (pa <= pb && pa <= pc ? left : pb <= pc ? up : corner);
                break;
            }
            default: throw new Error("png: filter " + filter);
            }
            out[y * stride + i] = value & 0xff;
        }
    }
    return { width, height, pixel: (x, y) => [...out.subarray(y * stride + x * 4, y * stride + x * 4 + 4)] };
}

module.exports = { BACKGROUND, monitor, client, world, decode };
