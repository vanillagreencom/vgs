// The daemon owns one synchronous audit writer. The router and network door
// must use before() after their own authorization and before starting work.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const Tools = require("./Tools.js");
const Redact = require("./Redact.js");
const Private = require("./Private.js");

const LINE_BYTES = 4 * 1024;
const STORE_BYTES = 64 * 1024 * 1024;
const DAY_MS = 24 * 60 * 60 * 1000;
const owners = new Set();
const effects = ["read", "reversible", "input", "persistent", "exec", "external", "destructive"];

function fail(code) {
    const error = new Error("jarvis: audit=" + code);
    error.code = code;
    throw error;
}

function dateOf(name) {
    if (!/^\d{4}-\d{2}-\d{2}\.jsonl$/.test(name)) fail("entry-name");
    const date = name.slice(0, 10);
    const time = Date.parse(date + "T00:00:00.000Z");
    if (!Number.isFinite(time) || new Date(time).toISOString().slice(0, 10) !== date) fail("entry-date");
    return time;
}

function regular(stat) {
    if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== process.getuid()) fail("file-type");
}

function encode(record) {
    const line = Buffer.from(JSON.stringify(record) + "\n");
    if (line.length > LINE_BYTES) fail("line-size");
    return line;
}

// A vision capture's facts: the layout box it read, the image's size and
// SHA-256, and how many private areas were painted. Numbers and a digest
// only, so no pixel or text of the image can enter the store.
function captureRecord(kind, tool, capture) {
    const whole = value => Number.isSafeInteger(value);
    if (kind !== "action" || !Object.hasOwn(Tools.TABLE, tool) || Tools.TABLE[tool].executor !== "vision"
            || capture === null || typeof capture !== "object"
            || Object.keys(capture).sort().join(",") !== "box,bytes,height,masks,scale,sha256,width"
            || !Array.isArray(capture.box) || capture.box.length !== 4 || !capture.box.every(whole)
            || capture.box[2] < 1 || capture.box[3] < 1 || typeof capture.scale !== "number"
            || !Number.isFinite(capture.scale) || capture.scale <= 0
            || ![capture.width, capture.height].every(value => whole(value) && value > 0)
            || ![capture.bytes, capture.masks].every(value => whole(value) && value >= 0)
            || typeof capture.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(capture.sha256)) fail("capture");
    return { box: capture.box.slice(), scale: capture.scale, width: capture.width, height: capture.height,
        bytes: capture.bytes, sha256: capture.sha256, masks: capture.masks };
}

function eventRecord(event, time) {
    if (event === null || typeof event !== "object") fail("event-shape");
    const { kind, gen, op, tool, effect, decision, confirmed, outcome } = event;
    if (!Number.isSafeInteger(gen) || gen < 0 || !Number.isSafeInteger(op) || op < 1) fail("identity");
    const decisions = kind === "action" ? ["allow", "confirm", "refuse"]
        : kind === "release" ? ["send", "ask", "withhold"] : null;
    if (decisions === null || !decisions.includes(decision)) fail("decision");
    if (effect !== null && !effects.includes(effect)) fail("effect");
    if (!["none", "physical", "voice"].includes(confirmed)) fail("confirmation");
    if (!["pending", "completed", "failed", "unknown", "cancelled"].includes(outcome)) fail("outcome");
    return { time, kind, gen, op,
        tool: kind === "release" ? "release" : Object.hasOwn(Tools.TABLE, tool) ? tool : "unknown",
        args: Redact.argumentsFor(kind, tool, event.args), effect, decision, confirmed, outcome,
        ...(event.capture === undefined ? {} : { capture: captureRecord(kind, tool, event.capture) }) };
}

/**
 * Acquire the daemon's only writer for an absolute Jarvis state directory.
 * auditDays is the manifest owner's setting; now returns wall-clock ms.
 * Creation does not open a store. close() ends this owner's lifetime.
 * The VGS instance/child lease supplies process exclusivity, not this API.
 */
function create({ state, auditDays = 30, now = Date.now }) {
    if (typeof state !== "string" || !path.isAbsolute(state) || path.normalize(state) !== state
            || state === "/" || /[\x00-\x1f\x7f]/.test(state)) fail("state-path");
    if (!Number.isInteger(auditDays) || auditDays < 1 || auditDays > 365) fail("audit-days");
    if (typeof now !== "function") fail("clock");
    if (owners.has(state)) fail("writer-owned");
    owners.add(state);
    const directory = path.join(state, "audit");
    let lifetime = "open";

    function clock() {
        const ms = now();
        if (!Number.isFinite(ms) || ms < 0) fail("clock-value");
        const time = new Date(ms).toISOString();
        if (time.length !== 24) fail("clock-value");
        return { time, today: Date.parse(time.slice(0, 10) + "T00:00:00.000Z"),
            file: path.join(directory, time.slice(0, 10) + ".jsonl") };
    }

    function scan(today) {
        let total = 0, oldest = null, expired = null;
        const entries = fs.opendirSync(directory);
        try {
            let entry;
            while ((entry = entries.readSync()) !== null) {
                const date = dateOf(entry.name);
                const file = path.join(directory, entry.name);
                const stat = fs.lstatSync(file);
                regular(stat);
                total += stat.size;
                if (!Number.isSafeInteger(total)) fail("store-size");
                const row = { file, date, bytes: stat.size };
                if (oldest === null || date < oldest.date) oldest = row;
                if (date <= today - auditDays * DAY_MS && (expired === null || date < expired.date)) expired = row;
            }
        } finally { entries.closeSync(); }
        return { total, oldest, expired };
    }

    function append(file, line) {
        const fd = fs.openSync(file, fs.constants.O_RDWR | fs.constants.O_CREAT | fs.constants.O_APPEND
            | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK, 0o600);
        try {
            const stat = fs.fstatSync(fd);
            regular(stat);
            fs.fchmodSync(fd, 0o600);
            if (stat.size > 0) {
                const tail = Buffer.alloc(1);
                if (fs.readSync(fd, tail, 0, 1, stat.size - 1) !== 1 || tail[0] !== 10) fail("partial-line");
            }
            const written = fs.writeSync(fd, line, 0, line.length);
            if (written !== line.length) {
                fs.ftruncateSync(fd, stat.size);
                fs.fsyncSync(fd);
                fail("short-write");
            }
            fs.fsyncSync(fd);
        } finally { fs.closeSync(fd); }
    }

    function persist(record, stamp) {
        Private.directory(state);
        Private.directory(directory);
        const line = encode(record);
        let inventory = scan(stamp.today);
        // Keep only the next oldest candidate, not an unbounded filename list.
        // Reserve one maximum-sized removal record as well as the new event.
        while (inventory.expired !== null || inventory.total + line.length + LINE_BYTES > STORE_BYTES) {
            const victim = inventory.expired || inventory.oldest;
            if (victim === null) fail("store-full");
            fs.unlinkSync(victim.file);
            append(stamp.file, encode({ time: stamp.time, kind: "prune", tool: "audit.prune",
                args: { date: new Date(victim.date).toISOString().slice(0, 10), bytes: victim.bytes,
                    reason: inventory.expired !== null ? "age" : "size" },
                effect: "persistent", decision: "remove", confirmed: "none", outcome: "completed" }));
            inventory = scan(stamp.today);
        }
        append(stamp.file, line);
        // Persist directory entries too, including a new daily file/removal.
        for (const folder of [directory, state]) {
            const fd = fs.openSync(folder, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
            try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
        }
    }

    function attempt(build) {
        try {
            if (lifetime !== "open") fail("writer-closed");
            const stamp = clock();
            persist(build(stamp.time), stamp);
            return { kind: "recorded" };
        } catch (error) {
            // Filesystem messages can contain private paths. Only keyed causes
            // leave this boundary; no caller argument or error body is logged.
            return { kind: "refuse", reason: "audit-write", cause: error.code || "event-invalid" };
        }
    }

    function record(event) { return attempt(time => eventRecord(event, time)); }

    return Object.freeze({
        /** Record a decision or later outcome, including refused/held calls. */
        record,
        /**
         * Persist a pending authorized action/release before invoking start.
         * This is the audit gate only, not a policy or approval judge.
         * start may return a promise; executor results never enter this store.
         */
        before(event, start) {
            if (!event || event.outcome !== "pending" || typeof start !== "function") fail("start-shape");
            const audit = record(event);
            if (audit.kind === "refuse") return audit;
            return { kind: "started", audit, value: start() };
        },
        /** Privacy shutdown cannot depend on a writable audit store. */
        cleanup(kind, start) {
            if (!["stop", "mute", "teardown"].includes(kind) || typeof start !== "function") fail("cleanup-shape");
            const audit = attempt(time => ({ time, kind: "cleanup", tool: kind, args: {},
                effect: "reversible", decision: "allow", confirmed: "none", outcome: "pending" }));
            return { kind: "started", audit, value: start() };
        },
        close() {
            if (lifetime === "open") { lifetime = "closed"; owners.delete(state); }
        }
    });
}

module.exports = { create };
