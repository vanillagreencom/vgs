// Coding-task records, not process control. task-event owns the writer lock.
// TaskRunner.js and task-run.py supply process facts; profiles supply hook events.
// D072 defines the four independent facts. No process is probed or signalled.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const MAX_EVENTS = 2000;
const MAX_BYTES = 8192;
const MAX_ENDED = 50;

function fail(reason, file = "") {
    throw new Error("jarvis: tasks=" + reason + (file === "" ? "" : " path=" + file));
}

function shape(value, fields) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
        && Object.keys(value).sort().join(",") === fields.slice().sort().join(",");
}

function text(value) {
    return typeof value === "string" && value.length > 0 && !/[\x00-\x1f\x7f]/.test(value);
}

function idOf(id) {
    if (typeof id !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(id)) fail("id");
    return id;
}

function absolute(file) {
    if (!text(file) || !path.isAbsolute(file)) fail("absolute-path");
    return file;
}

// All errors retain their actual I/O cause. ENOENT is absence only where
// this format expressly permits it (new store or missing overflow marker).
function io(action, file, operation) {
    try { return operation(); }
    catch (error) { fail(action + ":" + (error.code || error.message), file); }
}

function directory(file) {
    io("mkdir", file, () => fs.mkdirSync(file, { recursive: true, mode: 0o700 }));
    const stat = io("stat", file, () => fs.lstatSync(file));
    if (!stat.isDirectory() || stat.isSymbolicLink()) fail("directory", file);
    io("chmod", file, () => fs.chmodSync(file, 0o700));
}

function entries(file) {
    const stat = io("stat", file, () => fs.lstatSync(file));
    if (!stat.isDirectory() || stat.isSymbolicLink()) fail("directory", file);
    return io("readdir", file, () => fs.readdirSync(file, { withFileTypes: true }));
}

function json(file) {
    const fd = io("open", file, () => fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW));
    try {
        const stat = io("stat", file, () => fs.fstatSync(fd));
        if (!stat.isFile()) fail("record-file", file);
        if (stat.size > MAX_BYTES) fail("record-bytes", file);
        // Read a ceiling plus one byte, even if a producer replaces or grows
        // a file after fstat. No unbounded read precedes the byte gate.
        const buffer = Buffer.alloc(MAX_BYTES + 1);
        const count = io("read", file, () => fs.readSync(fd, buffer, 0, buffer.length, 0));
        if (count > MAX_BYTES) fail("record-bytes", file);
        try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, count))); }
        catch (error) { fail("parse:" + error.message, file); }
    } finally { io("close", file, () => fs.closeSync(fd)); }
}

function atomic(file, value) {
    const wire = JSON.stringify(value) + "\n";
    const temporary = path.join(path.dirname(file), "." + crypto.randomUUID() + ".tmp");
    io("write", temporary, () => fs.writeFileSync(temporary, wire, { flag: "wx", mode: 0o600 }));
    try { io("rename", file, () => fs.renameSync(temporary, file)); }
    finally {
        if (fs.existsSync(temporary)) io("unlink", temporary, () => fs.unlinkSync(temporary));
    }
}

// Invocation-local profiles translate vendor hooks to this one vocabulary.
// Stop produces turn-ended only. It never clears a question or permission.
function eventData(kind, data) {
    switch (kind) {
    case "started":
        if (!shape(data, ["pid", "pgid", "sid", "startTime"]) || !Number.isSafeInteger(data.pid) || data.pid < 1
            || !Number.isSafeInteger(data.pgid) || data.pgid < 1 || !Number.isSafeInteger(data.sid) || data.sid < 1
            || typeof data.startTime !== "string" || !/^[0-9]+$/.test(data.startTime)) fail("started");
        break;
    case "exited":
        if (!shape(data, ["code"]) || !Number.isSafeInteger(data.code)) fail("exit-code");
        break;
    case "turn-failed":
        if (!shape(data, ["kind"]) || !text(data.kind)) fail("failure-kind");
        break;
    case "wait":
        if (!shape(data, ["kind"]) || !["none", "permission", "question", "idle"].includes(data.kind)) fail("wait");
        break;
    case "outcome":
        if (!shape(data, ["kind"]) || !["reported-ok", "reported-failed"].includes(data.kind)) fail("outcome");
        break;
    case "alive":
    case "lost":
    case "stopped":
    case "working":
    case "turn-ended":
        if (!shape(data, [])) fail("empty-event");
        break;
    default:
        fail("event-kind");
    }
    return data;
}

function eventRecord(record, seq) {
    if (!shape(record, ["v", "seq", "at", "kind", "data"]) || record.v !== 1
        || record.seq !== seq || !Number.isSafeInteger(record.at) || record.at < 0) fail("event-record");
    eventData(record.kind, record.data);
    return record;
}

function terminalKind(kind) {
    return kind === "exited" || kind === "lost" || kind === "stopped";
}

function metadata(record, id) {
    if (!shape(record, ["v", "id", "goal", "cwd", "agent", "account", "createdAt", "engine"]) || record.v !== 1
        || record.id !== id || typeof record.goal !== "string" || record.goal.length === 0 || !text(record.agent)
        || typeof record.account !== "string" || /[\x00-\x1f\x7f]/.test(record.account)
        || !Number.isSafeInteger(record.createdAt) || record.createdAt < 0) fail("task-record");
    absolute(record.cwd);
    absolute(record.engine);
    return record;
}

// Returned state is a view. Only raw facts and task metadata reach disk.
function stateOf(facts, noisy) {
    if (noisy) return "noisy";
    if (facts.process.kind === "stopped") return "stopped";
    if (facts.process.kind === "lost") return "lost";
    if (facts.turn.kind === "turn-failed") return "failed";
    if (facts.outcome.kind === "reported-failed") return "reported-failed";
    if (facts.process.kind === "exited") {
        if (facts.process.code !== 0) return "failed";
        return facts.outcome.kind === "reported-ok" ? "reported-ok" : "exited";
    }
    if (facts.process.kind === "starting") return "starting";
    if (facts.wait.kind !== "none") return "waiting";
    if (facts.outcome.kind === "reported-ok") return "reported-ok";
    return facts.turn.kind === "turn-ended" ? "waiting" : "working";
}

// Replay is the sole state judge for the daemon and later task consumers.
function derive(events, noisy = false, terminal = null) {
    const facts = { process: { kind: "starting" }, turn: { kind: "working" },
        wait: { kind: "none" }, outcome: { kind: "none" } };
    let endedAt = null;
    let identity = null;
    function apply(event) {
        // The controller writes stopped only after the group read empty. The
        // launcher's own exit record can land after it and changes nothing.
        if (facts.process.kind === "stopped" && ["started", "alive", "exited", "lost"].includes(event.kind)) return;
        switch (event.kind) {
        case "started":
            identity = { ...event.data };
            facts.process = { kind: "alive" };
            endedAt = null;
            break;
        case "alive": facts.process = { kind: "alive" }; endedAt = null; break;
        case "exited": facts.process = { kind: "exited", code: event.data.code }; endedAt = event.at; break;
        case "lost": facts.process = { kind: "lost" }; endedAt = event.at; break;
        case "stopped": facts.process = { kind: "stopped" }; endedAt = event.at; break;
        case "working": facts.turn = { kind: "working" }; break;
        case "turn-ended":
            if (facts.turn.kind !== "turn-failed") facts.turn = { kind: "turn-ended" };
            break;
        case "turn-failed": facts.turn = { kind: "turn-failed", failure: event.data.kind }; break;
        case "wait": facts.wait = { kind: event.data.kind }; break;
        case "outcome": facts.outcome = { kind: event.data.kind }; break;
        default: fail("event-kind");
        }
    }
    for (const event of events) apply(event);
    if (terminal !== null) apply(terminal);
    return { ...facts, state: stateOf(facts, noisy), identity, endedAt };
}

// Data copies remain readable after a rescan deletes the plugin snapshot.
// Both files enter under one directory rename; consumers never see half a copy.
function publish(data, source) {
    absolute(data);
    const files = ["Tasks.js", "task-event"];
    const contents = files.map(file => io("engine-read", path.join(source, file), () => fs.readFileSync(path.join(source, file))));
    const hash = crypto.createHash("sha256");
    for (let i = 0; i < files.length; i++) hash.update(files[i]).update("\0").update(contents[i]);
    const parent = path.join(data, "engine");
    directory(parent);
    const target = path.join(parent, hash.digest("hex"));
    if (!fs.existsSync(target)) {
        const temporary = io("engine-mkdtemp", parent, () => fs.mkdtempSync(path.join(parent, ".copy-")));
        try {
            io("engine-chmod", temporary, () => fs.chmodSync(temporary, 0o700));
            for (let i = 0; i < files.length; i++)
                io("engine-write", files[i], () => fs.writeFileSync(path.join(temporary, files[i]), contents[i], { flag: "wx", mode: 0o600 }));
            io("engine-rename", target, () => fs.renameSync(temporary, target));
        } finally { io("engine-cleanup", temporary, () => fs.rmSync(temporary, { recursive: true, force: true })); }
    }
    const targetStat = io("engine-stat", target, () => fs.lstatSync(target));
    if (!targetStat.isDirectory() || targetStat.isSymbolicLink() || (targetStat.mode & 0o077) !== 0)
        fail("engine-directory", target);
    for (let i = 0; i < files.length; i++) {
        const file = path.join(target, files[i]);
        const stat = io("engine-stat", file, () => fs.lstatSync(file));
        if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0) fail("engine-file", file);
        const actual = io("engine-read", file, () => fs.readFileSync(file));
        if (!actual.equals(contents[i])) fail("engine-content", file);
    }
    return path.join(target, "task-event");
}

class Store {
    // clock belongs to the owner; tests inject it rather than waiting.
    constructor(state, clock = Date.now) {
        this.root = path.join(absolute(state), "tasks");
        this.clock = clock;
        directory(state);
        directory(this.root);
        this.lock = path.join(state, "tasks.lock");
        const fd = io("lock-open", this.lock, () => fs.openSync(this.lock,
            fs.constants.O_CREAT | fs.constants.O_APPEND | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600));
        try { io("lock-chmod", this.lock, () => fs.fchmodSync(fd, 0o600)); }
        finally { io("lock-close", this.lock, () => fs.closeSync(fd)); }
    }

    read(id) {
        const folder = path.join(this.root, idOf(id));
        const stat = io("stat", folder, () => fs.lstatSync(folder));
        if (!stat.isDirectory() || stat.isSymbolicLink()) fail("task-directory", folder);
        const record = metadata(json(path.join(folder, "task.json")), id);
        const eventDir = path.join(folder, "events");
        const names = entries(eventDir);
        const events = [];
        for (const entry of names.sort((a, b) => a.name.localeCompare(b.name))) {
            if (/^\.[0-9a-f-]+\.tmp$/.test(entry.name) && entry.isFile()) continue;
            if (!entry.isFile() || !/^[0-9]{4}\.json$/.test(entry.name)) fail("event-file", path.join(eventDir, entry.name));
            events.push(eventRecord(json(path.join(eventDir, entry.name)), events.length + 1));
            if (entry.name !== String(events.length).padStart(4, "0") + ".json") fail("event-sequence", eventDir);
            if (events.length > MAX_EVENTS) fail("event-count", eventDir);
        }
        let dropped = 0;
        let terminal = null;
        const marker = path.join(folder, "noisy.json");
        let markerStat = null;
        try { markerStat = fs.lstatSync(marker); }
        catch (error) { if (error.code !== "ENOENT") fail("stat:" + error.code, marker); }
        if (markerStat !== null) {
            const value = json(marker);
            if (!shape(value, ["v", "dropped", "terminal"]) || value.v !== 1
                || !Number.isSafeInteger(value.dropped) || value.dropped < 1) fail("noisy-record", marker);
            dropped = value.dropped;
            if (value.terminal !== null) {
                if (events.length !== MAX_EVENTS) fail("terminal-count", marker);
                terminal = eventRecord(value.terminal, events.length + 1);
                if (!terminalKind(terminal.kind)) fail("terminal-kind", marker);
            }
        }
        return { ...record, ...derive(events, dropped > 0, terminal), events, terminal, noisy: dropped > 0, dropped };
    }

    list() {
        const records = [];
        for (const entry of entries(this.root)) {
            // A create's unpublished directory is never a task.
            if (entry.name.startsWith(".create-") && entry.isDirectory()) continue;
            if (!entry.isDirectory() || entry.isSymbolicLink()) fail("task-directory", path.join(this.root, entry.name));
            records.push(this.read(entry.name));
        }
        return records.sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));
    }

    // Writer operations are called only by task-event's flock-held worker.
    create(id, data, engine) {
        idOf(id);
        if (!shape(data, ["goal", "cwd", "agent", "account"])) fail("create-shape");
        const record = metadata({ v: 1, id, ...data, createdAt: this.clock(), engine: absolute(engine) }, id);
        if (Buffer.byteLength(JSON.stringify(record) + "\n") > MAX_BYTES) fail("record-bytes");
        const target = path.join(this.root, id);
        if (fs.existsSync(target)) fail("task-exists", target);
        const temporary = io("create", this.root, () => fs.mkdtempSync(path.join(this.root, ".create-")));
        try {
            directory(temporary);
            directory(path.join(temporary, "events"));
            atomic(path.join(temporary, "task.json"), record);
            io("create-rename", target, () => fs.renameSync(temporary, target));
        } finally { io("create-cleanup", temporary, () => fs.rmSync(temporary, { recursive: true, force: true })); }
        this.prune();
        return { accepted: true, id };
    }

    append(id, kind, data, oversized = false) {
        const current = this.read(id);
        const folder = path.join(this.root, id);
        const event = { v: 1, seq: current.events.length + 1, at: this.clock(), kind, data };
        const reason = oversized || Buffer.byteLength(JSON.stringify(event) + "\n") > MAX_BYTES
            ? "record-bytes" : current.events.length >= MAX_EVENTS ? "event-count" : null;
        if (reason !== null) {
            const terminal = reason === "event-count" && terminalKind(kind)
                ? eventRecord(event, event.seq) : current.terminal;
            atomic(path.join(folder, "noisy.json"), {
                v: 1, dropped: Math.min(Number.MAX_SAFE_INTEGER, current.dropped + 1), terminal
            });
            if (terminal === event) this.prune();
            return { accepted: false, id, noisy: true, reason };
        }
        eventRecord(event, event.seq);
        atomic(path.join(folder, "events", String(event.seq).padStart(4, "0") + ".json"), event);
        this.prune();
        return { accepted: true, id, seq: event.seq };
    }

    prune() {
        const ended = this.list().filter(record => record.endedAt !== null)
            .sort((a, b) => a.endedAt - b.endedAt || a.createdAt - b.createdAt || a.id.localeCompare(b.id));
        const removed = ended.slice(0, Math.max(0, ended.length - MAX_ENDED));
        for (const record of removed) {
            const folder = path.join(this.root, record.id);
            io("prune", folder, () => fs.rmSync(folder, { recursive: true }));
        }
        return removed.length;
    }
}

module.exports = { Store, publish, derive, terminalKind };
