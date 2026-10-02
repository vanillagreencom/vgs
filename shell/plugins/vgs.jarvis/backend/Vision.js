// The vision executor: one capture of the screen, a monitor, a window, a
// region or an area the user draws, with every private window painted out
// before the image leaves this owner, answered as a screen-labelled PNG or
// its OCR text. Screen.js judges the geometry; DesktopSession lends the one
// Hyprland reader; Desktop.runCommand runs each command. Policy, approval,
// audit and release stay with the router and the brain's transport.
// Contract: docs/architecture/jarvis-vision.md.
"use strict";
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const Desktop = require("./Desktop.js");
const Private = require("./Private.js");
const Screen = require("./Screen.js");
const Tools = require("./Tools.js");

const COMMANDS = ["grim", "magick", "slurp", "tesseract"];
// The plan's screenshot bound (§ 3.11): captures one turn may take.
const TURN_LIMIT = 4;
// One image on the image route. A wire brain renders only the current
// turn's images, so the turn's four, base64-encoded, stay under its 20 MiB
// request bound.
const IMAGE_BYTES = 3 * 1024 * 1024;
// The wait before a retry, for the animation the change started: Hyprland
// 0.56.2's default global speed, 8 (src/config/shared/animation/AnimationTree.cpp),
// at hyprutils' 100 ms per unit (CBaseAnimatedVariable::getPercent). hyprctl
// reports animation goals, so a reading cannot see the animation end.
const SETTLE_MS = 800;
// Recovery bounds for a command that never answers, not measured latency
// budgets. slurp waits for the user to draw. The executor's whole bound
// stays under Session's 60 s thinking deadline.
const DEADLINES = Object.freeze({ grim: 5000, slurp: 15000, magick: 5000, tesseract: 15000 });
const SLACK_MS = 1000;
// Omarchy's capture-text flags, with automatic page segmentation for a
// whole screen in place of its single block.
const OCR = ["--oem", "1", "--psm", "3", "--dpi", "300", "-l", "eng", "-c", "preserve_interword_spaces=1"];
// slurp's default format, pinned: layout coordinates (slurp main.c).
const AREA_FORMAT = "%x,%y %wx%h";
const AREA = /^(-?\d{1,9}),(-?\d{1,9}) (\d{1,9})x(\d{1,9})\n?$/;
// slurp's first stderr line when the user cancels (slurp main.c, exit 1).
const CANCELLED = "selection cancelled";
const SIGNATURE = Buffer.from("89504e470d0a1a0a", "hex");

const answer = (outcome, value) => ({ outcome, content: typeof value === "string" ? value : JSON.stringify(value) });
const refuse = reason => answer("failed", { kind: "refuse", reason });

// The width and height a PNG's IHDR chunk states, or null for another file.
function pngSize(file) {
    const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
        const head = Buffer.alloc(24);
        if (fs.readSync(fd, head, 0, head.length, 0) !== head.length || !head.subarray(0, 8).equals(SIGNATURE)
                || head.toString("latin1", 12, 16) !== "IHDR") return null;
        return { width: head.readUInt32BE(16), height: head.readUInt32BE(20) };
    } finally { fs.closeSync(fd); }
}

// The whole file, or null past IMAGE_BYTES.
function image(file) {
    const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
        const stat = fs.fstatSync(fd);
        if (!stat.isFile()) throw new Error("jarvis: vision=image-type");
        if (stat.size > IMAGE_BYTES) return null;
        const bytes = Buffer.alloc(stat.size);
        if (fs.readSync(fd, bytes, 0, bytes.length, 0) !== bytes.length) throw new Error("jarvis: vision=image-read");
        return bytes;
    } finally { fs.closeSync(fd); }
}

// The byte count and SHA-256 of a file of any size.
function digest(file) {
    const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
        if (!fs.fstatSync(fd).isFile()) throw new Error("jarvis: vision=image-type");
        const hash = crypto.createHash("sha256");
        const chunk = Buffer.alloc(64 * 1024);
        let bytes = 0;
        for (let read; (read = fs.readSync(fd, chunk, 0, chunk.length, null)) > 0; bytes += read)
            hash.update(chunk.subarray(0, read));
        return { bytes, sha256: hash.digest("hex") };
    } finally { fs.closeSync(fd); }
}

function remove(file) {
    try { fs.unlinkSync(file); }
    catch (error) { if (error.code !== "ENOENT") throw error; }
}

function described(call, plan, masks) {
    const what = call.id === "vision.screen" ? "the whole screen"
        : call.id === "vision.monitor" ? "monitor " + call.args.monitor
        : call.id === "vision.window" ? "window " + call.args.window.toLowerCase()
        : call.id === "vision.area" ? "the area the user selected" : "the requested region";
    const { box, scale, image: size } = plan;
    return "Screen " + what + ": " + size.width + " by " + size.height + " pixels of layout " + box.x + "," + box.y
        + " " + box.w + "x" + box.h + " at scale " + scale + ". Image pixel (px, py) is layout point ("
        + box.x + " + px / " + scale + ", " + box.y + " + py / " + scale + ")."
        + (masks === 0 ? "" : " " + masks + " private window area" + (masks === 1 ? " is" : "s are") + " painted black.");
}

/**
 * create(options) builds the router's executor record and its lifetime.
 *   commands        command name to absolute file; grim and magick present
 *   environment     the daemon's; Desktop.runCommand picks each command's
 *   read, readMs    DesktopSession's reader and one read's bound
 *   directory       the private files' absolute directory
 *   state           Session's current record
 *   route()         "image" when the brain takes images, else "text"
 *   privateWindows()  the setting's current value
 *   onScreen        Dispatch.onScreen
 *   clock           {set, clear} for each command's deadline
 * Files left by a daemon that was killed are removed here.
 */
function create({ commands, environment, read, readMs, directory, state, route, privateWindows, onScreen, clock }) {
    if (typeof directory !== "string" || !path.isAbsolute(directory)) throw new Error("jarvis: vision=directory");
    fs.rmSync(directory, { recursive: true, force: true });
    const running = new Map();
    let taken = { turn: null, count: 0 };
    let closed = false;

    function run(name, args, signal, env) {
        return Desktop.runCommand(commands.get(name), name, { args, env }, { environment, signal, clock, deadline: DEADLINES[name] });
    }

    // The live turn the user started, which owns this running action.
    function turnOf(s) {
        if (s.turn.kind !== "thinking" || s.action.kind !== "running"
                || s.action.gen !== s.turn.gen || s.action.brain !== s.turn.op) return null;
        return s.turn.gen + ":" + s.turn.op;
    }

    // The router's synchronous rejudge: lock, policy and the live action.
    function halted(authorize) {
        const verdict = authorize(undefined);
        return verdict.kind === "allow" ? null : refuse(verdict.reason);
    }

    // seen maps each private window to the bounding box of every rectangle
    // a reading of this call reported for it.
    async function reading(call, seen) {
        const value = await read();
        if (value.kind !== "state") return { kind: "unread", answer: answer("failed", { kind: "failed", reason: "hyprland-read", detail: value.content }) };
        const plan = Screen.plan(call, value.state, privateWindows(), onScreen);
        if (plan.kind === "refuse") return { kind: "refused", answer: refuse(plan.reason) };
        for (const { address, rect } of plan.hidden)
            seen.set(address, seen.has(address) ? Screen.cover(seen.get(address), rect) : rect);
        return plan;
    }

    // The wait before a retry; false when the call was cancelled meanwhile.
    function settle(signal) {
        return new Promise(resolve => {
            if (signal.aborted) { resolve(false); return; }
            const stop = () => { clock.clear(timer); resolve(false); };
            const timer = clock.set(() => { signal.removeEventListener("abort", stop); resolve(true); }, SETTLE_MS);
            signal.addEventListener("abort", stop, { once: true });
        });
    }

    // One capture between two readings. Its masks hold only while both
    // readings share their key; otherwise the image is deleted.
    async function shoot(call, authorize, signal, files, seen) {
        const before = await reading(call, seen);
        if (before.kind !== "capture") return { kind: "failed", answer: before.answer };
        const early = halted(authorize);
        if (early !== null) return { kind: "failed", answer: early };
        Private.directory(directory);
        const file = path.join(directory, crypto.randomUUID() + ".png");
        files.push(file);
        const shot = await run("grim", [...before.grim, file], signal);
        if (shot.kind !== "exited" || shot.code !== 0) return { kind: "failed", answer: Desktop.failure(call, "grim", shot) };
        const after = await reading(call, seen);
        // An image taken across a lock, or after the action ended, is deleted.
        const late = halted(authorize);
        if (late !== null) { remove(file); return { kind: "failed", answer: late }; }
        if (after.kind === "unread") { remove(file); return { kind: "failed", answer: after.answer }; }
        if (after.kind !== "capture" || after.key !== before.key) { remove(file); return { kind: "changed" }; }
        return { kind: "captured", plan: before, file };
    }

    // rects are the private windows' rectangles every reading of the call saw.
    async function finish(call, plan, file, signal, files, way, rects) {
        const size = pngSize(file);
        if (size === null || size.width !== plan.image.width || size.height !== plan.image.height) return refuse("image-size");
        const masks = Screen.masks(plan, rects);
        let out = file;
        if (masks.length !== 0) {
            out = path.join(directory, crypto.randomUUID() + ".png");
            files.push(out);
            const draws = masks.flatMap(mask => ["-draw",
                "rectangle " + mask.x0 + "," + mask.y0 + " " + (mask.x1 - 1) + "," + (mask.y1 - 1)]);
            // Coders are named, so neither file is read or written as another format.
            const painted = await run("magick", ["png:" + file, "+antialias", "-fill", "black", ...draws, "PNG32:" + out],
                signal, { MAGICK_TEMPORARY_PATH: directory });
            if (painted.kind !== "exited" || painted.code !== 0) return Desktop.failure(call, "magick", painted);
            const masked = pngSize(out);
            if (masked === null || masked.width !== size.width || masked.height !== size.height) return refuse("mask-failed");
            remove(file);
        }
        const text = described(call, plan, masks.length);
        const capture = facts => ({ box: [plan.box.x, plan.box.y, plan.box.w, plan.box.h], scale: plan.scale,
            width: size.width, height: size.height, ...facts, masks: masks.length });
        switch (way) {
        case "image": {
            const bytes = image(out);
            if (bytes === null) return refuse("image-bytes");
            return { outcome: "completed", content: text, image: { type: "image/png", bytes },
                capture: capture({ bytes: bytes.length, sha256: crypto.createHash("sha256").update(bytes).digest("hex") }) };
        }
        case "text": {
            // No image leaves on this route, so no image bound applies.
            const facts = digest(out);
            // OCR reads the painted file, never the capture.
            const ocr = await run("tesseract", [out, "stdout", ...OCR], signal);
            // Like clipboard.read, text past the output bound is answered cut;
            // the router marks its own cut.
            const cut = ocr.kind === "stopped" && ocr.reason === "output-limit";
            if (!cut && (ocr.kind !== "exited" || ocr.code !== 0)) return Desktop.failure(call, "tesseract", ocr);
            const found = ocr.stdout.trim();
            return { outcome: "completed", capture: capture(facts), content: text + " The brain takes no image, so this is its OCR text.\n"
                + (found === "" ? "[no text recognized]" : found) };
        }
        default: throw new Error("jarvis: vision=route " + way);
        }
    }

    async function perform(call, authorize, signal, files) {
        const turn = turnOf(state());
        if (turn === null) return refuse("outside-turn");
        // Known before any effect: no capture is taken for a brain that
        // could not read it.
        const way = route();
        if (way !== "image" && way !== "text") throw new Error("jarvis: vision=route " + way);
        if (way === "text" && !commands.has("tesseract")) return refuse("ocr-unavailable");
        if (taken.turn !== turn) taken = { turn, count: 0 };
        if (taken.count >= TURN_LIMIT) return refuse("screenshot-limit");
        taken.count += 1;
        let target = call;
        if (call.id === "vision.area") {
            const early = halted(authorize);
            if (early !== null) return early;
            const picked = await run("slurp", ["-f", AREA_FORMAT], signal);
            if (picked.kind === "exited" && picked.code !== 0 && picked.stderr.split("\n")[0].trim() === CANCELLED)
                return refuse("area-cancelled");
            if (picked.kind !== "exited" || picked.code !== 0) return Desktop.failure(call, "slurp", picked);
            const area = AREA.exec(picked.stdout);
            if (area === null || Number(area[3]) < 1 || Number(area[4]) < 1) return refuse("area-shape");
            target = { id: "vision.region", args: { x: Number(area[1]), y: Number(area[2]), width: Number(area[3]), height: Number(area[4]) } };
        }
        const seen = new Map();
        let shot = await shoot(target, authorize, signal, files, seen);
        // A change between the readings retries once, after its animation.
        if (shot.kind === "changed") {
            if (!await settle(signal)) return answer("failed", { kind: "stopped", reason: "cancelled" });
            shot = await shoot(target, authorize, signal, files, seen);
        }
        if (shot.kind === "changed") return refuse("screen-changed");
        if (shot.kind === "failed") return shot.answer;
        return finish(call, shot.plan, shot.file, signal, files, way, [...seen.values()]);
    }

    function start(call, done, authorize) {
        if (closed || !Object.hasOwn(Tools.TABLE, call.id) || Tools.TABLE[call.id].executor !== "vision"
                || running.has(call) || typeof authorize !== "function")
            throw new Error("jarvis: vision=call id=" + call.id);
        const abort = new AbortController();
        running.set(call, abort);
        const files = [];
        // Like the router's own start, an internal error becomes a failed
        // outcome without its text; the daemon's stderr names its cause.
        perform(call, authorize, abort.signal, files).catch(error => {
            process.stderr.write("jarvis: vision=internal cause=" + (error?.code ?? error?.message ?? "unknown") + "\n");
            return answer("failed", "executor-failed");
        }).then(value => {
            running.delete(call);
            let result = value;
            try { for (const file of files) remove(file); }
            catch { result = answer("failed", { kind: "failed", reason: "cleanup" }); }
            done(result);
        });
    }

    const record = { commands: [...commands.keys()], cancellable: true, start,
        timeoutMs: DEADLINES.slurp + 2 * (2 * readMs + DEADLINES.grim) + SETTLE_MS + DEADLINES.magick + DEADLINES.tesseract + SLACK_MS,
        cancel: call => { running.get(call)?.abort(); } };

    return { record, close() {
        closed = true;
        for (const abort of running.values()) abort.abort();
        fs.rmSync(directory, { recursive: true, force: true });
    } };
}

/**
 * install({router, session, find, ...options}) registers the vision
 * executor once the desktop session's probe reached Hyprland, when grim and
 * magick are on PATH: an image whose private windows cannot be painted is
 * not one this executor sends. session is DesktopSession.install's
 * lifetime; options are create's own.
 */
function install({ router, session, find, ...options }) {
    const commands = new Map();
    for (const name of COMMANDS) {
        const file = find(name);
        if (file !== null) commands.set(name, file);
    }
    if (!commands.has("grim") || !commands.has("magick")) return { close() {} };
    const vision = create({ commands, read: session.read, readMs: session.readMs, ...options });
    let lifetime = "open";
    session.ready.then(reached => { if (reached && lifetime === "open") router.register("vision", vision.record); });
    return { close() { lifetime = "closed"; vision.close(); } };
}

module.exports = { install };
