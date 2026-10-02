// The relay between a held agent hook and the user's answer. A hook that
// holds a permission request or a question publishes one prompt file and
// waits for one answer file beside it; the daemon lists prompts and writes
// the answer the user gave. This module is the one judge of both shapes and
// of which answer fits which prompt. It runs from the task engine copy
// (Tasks.publish), because a held hook outlives the plugin snapshot. A
// prompt is not a task record: the hook reports its wait through task-event.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

// The plan's answer window: a hook holds a prompt this long at most.
const WINDOW_MS = 600000;
const MIN_WINDOW_MS = 1000;
const MAX_TEXT = 4096;
const MAX_BYTES = 16384;
// Prompts held at once across every task; past it a hook does not hold.
const MAX_PROMPTS = 32;
const KINDS = ["permission", "question"];

function fail(reason, file = "") {
    throw new Error("jarvis: relay=" + reason + (file === "" ? "" : " path=" + file));
}

function shape(value, fields) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
        && Object.keys(value).sort().join(",") === fields.slice().sort().join(",");
}

function name(value) {
    return typeof value === "string" && /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(value);
}

const CONTROL = /[\x00-\x09\x0b-\x1f\x7f]/g;

/** Text the user reads or hears: control characters other than a line
 * break become spaces, and it is cut to MAX_TEXT characters. */
function clip(text) {
    const flat = String(text).replace(CONTROL, " ");
    return flat.length > MAX_TEXT ? flat.slice(0, MAX_TEXT - 1) + "…" : flat;
}

function promptRecord(value) {
    if (!shape(value, ["v", "id", "task", "kind", "tool", "text", "at", "deadline"]) || value.v !== 1
            || !name(value.id) || !name(value.task) || !KINDS.includes(value.kind)
            || (value.kind === "permission" ? !(typeof value.tool === "string" && /^[A-Za-z0-9_.:-]{1,128}$/.test(value.tool))
                : value.tool !== null)
            || typeof value.text !== "string" || value.text.length > MAX_TEXT
            || !Number.isSafeInteger(value.at) || !Number.isSafeInteger(value.deadline) || value.deadline <= value.at)
        fail("prompt-shape");
    return value;
}

/** The one answer judge: allow or deny answers a permission, a non-empty
 * reply answers a question. Anything else is null. */
function answerRecord(value, kind) {
    switch (kind) {
    case "permission":
        return shape(value, ["v", "kind"]) && value.v === 1 && ["allow", "deny"].includes(value.kind) ? value : null;
    case "question":
        return shape(value, ["v", "kind", "text"]) && value.v === 1 && value.kind === "reply"
            && typeof value.text === "string" && value.text.trim() !== "" && value.text.length <= MAX_TEXT
            && !new RegExp(CONTROL.source).test(value.text) ? value : null;
    default:
        fail("prompt-kind");
    }
}

const promptFile = (directory, task, id) => path.join(directory, task + "." + id + ".prompt.json");
const answerFile = (directory, task, id) => path.join(directory, task + "." + id + ".answer.json");

function io(action, file, operation) {
    try { return operation(); }
    catch (error) {
        if (error.message.startsWith("jarvis: relay=")) throw error;
        fail(action + ":" + (error.code || error.message), file);
    }
}

function directoryOf(directory) {
    if (typeof directory !== "string" || !path.isAbsolute(directory)) fail("directory");
    io("mkdir", directory, () => fs.mkdirSync(directory, { recursive: true, mode: 0o700 }));
    const stat = io("stat", directory, () => fs.lstatSync(directory));
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid()) fail("directory", directory);
    io("chmod", directory, () => fs.chmodSync(directory, 0o700));
    return directory;
}

// null when the file is absent; a link, another owner or a wide mode is refused.
function readJson(file) {
    let fd;
    try { fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW); }
    catch (error) {
        if (error.code === "ENOENT") return null;
        fail("open:" + error.code, file);
    }
    try {
        const stat = io("stat", file, () => fs.fstatSync(fd));
        if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077) !== 0) fail("file", file);
        const buffer = Buffer.alloc(MAX_BYTES + 1);
        const count = io("read", file, () => fs.readSync(fd, buffer, 0, buffer.length, 0));
        if (count > MAX_BYTES) fail("bytes", file);
        try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, count))); }
        catch { fail("json", file); }
    } finally { io("close", file, () => fs.closeSync(fd)); }
}

// ask sweeps expired prompts before it adds one and refuses past
// MAX_PROMPTS live ones, so no more than MAX_PROMPTS prompt files exist.
function prompts(directory) {
    const names = io("readdir", directory, () => fs.readdirSync(directory)).filter(entry => entry.endsWith(".prompt.json"));
    if (names.length > MAX_PROMPTS) fail("prompt-count", directory);
    const found = [];
    for (const entry of names.sort()) {
        const value = readJson(path.join(directory, entry));
        // A hook removes its prompt when it ends; a removal between the
        // listing and the read is that end, not a defect.
        if (value === null) continue;
        promptRecord(value);
        if (entry !== value.task + "." + value.id + ".prompt.json") fail("prompt-name", path.join(directory, entry));
        found.push(value);
    }
    return found;
}

/** Hook side: the prompt and its answer leave together. */
function withdraw(directory, prompt) {
    for (const file of [promptFile(directory, prompt.task, prompt.id), answerFile(directory, prompt.task, prompt.id)])
        io("unlink", file, () => fs.rmSync(file, { force: true }));
}

/**
 * Hook side. Publish one prompt for task, or null when MAX_PROMPTS are held,
 * so the hook gives no decision and the agent asks in its own terminal.
 * detail: { kind, tool, text }; now and window in milliseconds. A prompt past
 * its deadline belongs to a hook that ended or was killed, and is removed.
 */
function ask(directory, task, detail, now, window) {
    directoryOf(directory);
    if (!name(task)) fail("task");
    if (!Number.isSafeInteger(window) || window < MIN_WINDOW_MS || window > WINDOW_MS) fail("window");
    const live = [];
    for (const item of prompts(directory)) {
        if (item.deadline <= now) withdraw(directory, item);
        else live.push(item);
    }
    if (live.length >= MAX_PROMPTS) return null;
    const value = promptRecord({ v: 1, id: crypto.randomUUID(), task, kind: detail.kind,
        tool: detail.kind === "permission" ? detail.tool : null, text: clip(detail.text), at: now, deadline: now + window });
    const temporary = path.join(directory, "." + crypto.randomUUID() + ".tmp");
    io("write", temporary, () => fs.writeFileSync(temporary, JSON.stringify(value), { flag: "wx", mode: 0o600 }));
    try { io("rename", temporary, () => fs.renameSync(temporary, promptFile(directory, task, value.id))); }
    finally { fs.rmSync(temporary, { force: true }); }
    return value;
}

/** Hook side: the judged answer to prompt, or null while none has come. */
function answerTo(directory, prompt) {
    const value = readJson(answerFile(directory, prompt.task, prompt.id));
    if (value === null) return null;
    const answer = answerRecord(value, prompt.kind);
    if (answer === null) fail("answer-shape", answerFile(directory, prompt.task, prompt.id));
    return answer;
}

/** Daemon side: the unanswered prompts still inside their window, oldest
 * first. An answered prompt stays on disk until its hook reads the answer;
 * it is not asked again. A missing directory means no hook has held one. */
function pending(directory, now) {
    if (!fs.existsSync(directory)) return [];
    directoryOf(directory);
    return prompts(directory).filter(item => item.deadline > now && !fs.existsSync(answerFile(directory, item.task, item.id)))
        .sort((a, b) => a.at - b.at || a.id.localeCompare(b.id));
}

/**
 * Daemon side: record the user's answer to one held prompt, once.
 * "answered", or a refusal: prompt-unknown, prompt-expired, answer-invalid
 * (the wrong kind or shape for the prompt), answered-already.
 */
function answer(directory, task, id, value, now) {
    if (!name(task) || !name(id) || !fs.existsSync(directory)) return "prompt-unknown";
    directoryOf(directory);
    const prompt = readJson(promptFile(directory, task, id));
    if (prompt === null) return "prompt-unknown";
    promptRecord(prompt);
    if (prompt.task !== task || prompt.id !== id) fail("prompt-name", promptFile(directory, task, id));
    if (prompt.deadline <= now) return "prompt-expired";
    const judged = answerRecord(value, prompt.kind);
    if (judged === null) return "answer-invalid";
    const temporary = path.join(directory, "." + crypto.randomUUID() + ".tmp");
    io("write", temporary, () => fs.writeFileSync(temporary, JSON.stringify(judged), { flag: "wx", mode: 0o600 }));
    try {
        // A link fails where the answer exists: one answer per prompt.
        fs.linkSync(temporary, answerFile(directory, task, id));
        return "answered";
    } catch (error) {
        if (error.code === "EEXIST") return "answered-already";
        fail("link:" + (error.code || error.message), answerFile(directory, task, id));
    } finally { fs.rmSync(temporary, { force: true }); }
}

module.exports = { WINDOW_MS, MIN_WINDOW_MS, MAX_PROMPTS, MAX_TEXT, ask, answerTo, withdraw, pending, answer };
