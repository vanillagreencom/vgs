// The one judge from a Hyprland state reading and a vision call to a capture
// plan: the layout box grim captures, the scale its image takes, and the
// image pixels each private window covers. Pure: it runs no process and
// touches no file. Contract: docs/architecture/jarvis-vision.md.
"use strict";

function refuse(reason) { return { kind: "refuse", reason }; }
const integer = value => Number.isSafeInteger(value);

/**
 * An output's box in layout coordinates, or null for a reading this judge
 * cannot place. Hyprland 0.56.2 prints `width` and `height` as the mode in
 * device pixels; its logical size is that mode turned a quarter for an odd
 * transform (wl_output_transform 1, 3, 5, 7), divided by the scale and
 * rounded (CMonitor::applyMonitorRule, src/output/Monitor.cpp).
 */
function layoutBox(monitor) {
    if (!monitor || ![monitor.x, monitor.y, monitor.width, monitor.height,
        monitor.activeWorkspace?.id, monitor.specialWorkspace?.id].every(integer)
            || monitor.width < 1 || monitor.height < 1 || typeof monitor.scale !== "number"
            || !Number.isFinite(monitor.scale) || monitor.scale <= 0
            || !Number.isInteger(monitor.transform) || monitor.transform < 0 || monitor.transform > 7)
        return null;
    const turned = monitor.transform % 2 === 1;
    return { x: monitor.x, y: monitor.y,
        w: Math.round((turned ? monitor.height : monitor.width) / monitor.scale),
        h: Math.round((turned ? monitor.width : monitor.height) / monitor.scale) };
}

function intersect(a, b) {
    const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
    const w = Math.min(a.x + a.w, b.x + b.w) - x, h = Math.min(a.y + a.h, b.y + b.h) - y;
    return w > 0 && h > 0 ? { x, y, w, h } : null;
}

function clientBox(client) {
    const at = client.at, size = client.size;
    if (!Array.isArray(at) || !Array.isArray(size) || at.length !== 2 || size.length !== 2
            || ![...at, ...size].every(integer)) return null;
    return { x: at[0], y: at[1], w: size[0], h: size[1] };
}

/**
 * The patterns of a privateWindows value: comma-separated, trimmed, lower
 * case, none empty. Each matches as a substring of a window's class,
 * initial class, title or initial title, without case.
 */
function patterns(value) {
    if (typeof value !== "string") throw new Error("jarvis: screen=private-windows");
    return value.split(",").map(pattern => pattern.trim().toLowerCase()).filter(pattern => pattern !== "");
}

function isPrivate(client, list) {
    const names = [client.class, client.initialClass, client.title, client.initialTitle]
        .filter(name => typeof name === "string").map(name => name.toLowerCase());
    return list.some(pattern => names.some(name => name.includes(pattern)));
}

/**
 * The capture box, its scale and grim's target arguments for one call.
 * grim renders every output into one image of the box in layout
 * orientation, each output's transform already applied, at one scale
 * (grim 1.5.0 render.c::render); `-s` pins that scale to the highest of
 * the outputs the box meets, the one grim itself would guess.
 */
function target(call, monitors, clients, onScreen, list) {
    const boxes = monitors.map(layoutBox);
    if (monitors.length === 0 || boxes.includes(null)) return refuse("monitor-shape");
    const meeting = box => monitors.filter((monitor, index) => intersect(boxes[index], box) !== null);
    const highest = list => Math.max(...list.map(monitor => monitor.scale));
    const geometry = box => box.x + "," + box.y + " " + box.w + "x" + box.h;
    const screen = boxes.reduce((all, box) => {
        const x = Math.min(all.x, box.x), y = Math.min(all.y, box.y);
        return { x, y, w: Math.max(all.x + all.w, box.x + box.w) - x, h: Math.max(all.y + all.h, box.y + box.h) - y };
    });
    switch (call.id) {
    case "vision.screen":
        return { kind: "target", box: screen, scale: highest(monitors), grim: [] };
    case "vision.monitor": {
        const index = monitors.findIndex(m => m.name === call.args.monitor || String(m.id) === call.args.monitor);
        if (index === -1) return refuse("monitor-absent");
        const monitor = monitors[index];
        return { kind: "target", box: boxes[index], scale: monitor.scale, grim: ["-o", monitor.name] };
    }
    case "vision.window": {
        const address = call.args.window.toLowerCase();
        const client = clients.find(c => c.mapped && String(c.address).toLowerCase() === address);
        if (client === undefined) return refuse("window-absent");
        const box = clientBox(client);
        if (box === null) return refuse("window-shape");
        if (!onScreen(client, monitors)) return refuse("window-hidden");
        // Painting the whole image out would answer nothing.
        if (isPrivate(client, list)) return refuse("private-window");
        const shown = meeting(box);
        if (shown.length === 0) return refuse("window-off-screen");
        return { kind: "target", box, scale: highest(shown), grim: ["-g", geometry(box)] };
    }
    case "vision.region": {
        const box = { x: call.args.x, y: call.args.y, w: call.args.width, h: call.args.height };
        const shown = meeting(box);
        // The screen's own bounds keep a region's image, and grim's
        // allocation for it, no larger than the whole screen's.
        if (shown.length === 0 || box.x < screen.x || box.y < screen.y
                || box.x + box.w > screen.x + screen.w || box.y + box.h > screen.y + screen.h)
            return refuse("region-off-screen");
        return { kind: "target", box, scale: highest(shown), grim: ["-g", geometry(box)] };
    }
    default: throw new Error("jarvis: screen=tool " + call.id);
    }
}

/**
 * plan(call, reading, privateWindows, onScreen) answers
 *   {kind:"capture", box, scale, grim, image:{width,height}, hidden, key}
 * or {kind:"refuse", reason}. reading is a Dispatch.revealState value;
 * onScreen is Dispatch.onScreen. hidden lists every mapped private window,
 * on any workspace, as {address, rect} in layout coordinates: Hyprland's
 * animation goal, not the rectangle drawn while it animates. key is the part
 * of the reading two plans of one call must share for an image to match its
 * masks: the box, the scale, each monitor's active and special workspace,
 * the set of mapped windows and every private window's rectangle.
 */
function plan(call, reading, privateWindows, onScreen) {
    const list = patterns(privateWindows);
    const clients = reading.clients.filter(client => client.mapped);
    const chosen = target(call, reading.monitors, clients, onScreen, list);
    if (chosen.kind === "refuse") return chosen;
    const { box, scale } = chosen;
    // grim sizes its image as (int)(width * scale) (render.c::render).
    const image = { width: Math.trunc(box.w * scale), height: Math.trunc(box.h * scale) };
    if (image.width < 1 || image.height < 1) return refuse("image-empty");
    const hidden = [];
    for (const client of clients.filter(client => isPrivate(client, list))) {
        const rect = clientBox(client);
        if (rect === null) return refuse("window-shape");
        hidden.push({ address: String(client.address).toLowerCase(), rect });
    }
    hidden.sort((a, b) => a.address < b.address ? -1 : a.address > b.address ? 1 : 0);
    const windows = clients.map(client => String(client.address).toLowerCase()).sort();
    const workspaces = reading.monitors.map(monitor => [monitor.name, monitor.activeWorkspace.id, monitor.specialWorkspace.id]);
    return { kind: "capture", box, scale, grim: ["-s", String(scale), ...chosen.grim], image, hidden,
        key: JSON.stringify({ box, scale, workspaces, windows, hidden }) };
}

/**
 * masks(plan, rects) answers the image pixel rectangles {x0, y0, x1, y1},
 * end exclusive, that cover each layout rectangle of rects inside the plan's
 * box: clipped to the box and rounded outward.
 */
function masks(plan, rects) {
    const { box, scale, image } = plan;
    const out = [];
    for (const rect of rects) {
        const part = intersect(rect, box);
        if (part === null) continue;
        out.push({ x0: Math.max(0, Math.floor((part.x - box.x) * scale)),
            y0: Math.max(0, Math.floor((part.y - box.y) * scale)),
            x1: Math.min(image.width, Math.ceil((part.x + part.w - box.x) * scale)),
            y1: Math.min(image.height, Math.ceil((part.y + part.h - box.y) * scale)) });
    }
    return out.filter(mask => mask.x1 > mask.x0 && mask.y1 > mask.y0);
}

/** The bounding box of two layout rectangles. */
function cover(a, b) {
    const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
    return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
}

module.exports = { plan, masks, cover };
