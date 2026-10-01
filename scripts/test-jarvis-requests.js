#!/usr/bin/env node
// The daemon's request owner against the real protocol judge and an
// injected clock. Synthetic requests from JarvisProtocol.js, 2026-10-01.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");
const tree = path.resolve(__dirname, "..");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/ShellRequests.js");
const Protocol = load(path.join(tree, "shell/plugins/vgs.jarvis/JarvisProtocol.js"));

function harness(ShellRequests) {
    const timers = new Map();
    let at = 0, serial = 0;
    const clock = { now: () => at, set: (fn, ms) => { const id = ++serial; timers.set(id, { fn, due: at + ms }); return id; },
        clear: id => timers.delete(id) };
    const written = [];
    const answers = [];
    const requests = ShellRequests.create({ Protocol, clock, write: fields => {
        Protocol.accept(JSON.stringify({ v: 1, type: "request", gen: 0, revision: "a".repeat(64), ...fields }), "daemon");
        written.push(fields);
    } });
    const send = (kind = "toast", args = ["Title", "Body"], timeoutMs = 100) => {
        const index = answers.length;
        answers.push([]);
        requests.send(kind, args, timeoutMs, value => answers[index].push(value));
        return index;
    };
    const reply = (id, kind = "toast", answer = "ok", data = null) =>
        requests.reply({ v: 1, type: "reply", gen: 0, revision: "a".repeat(64), id, kind, answer, data });
    const advance = ms => {
        at += ms;
        for (const [id, timer] of [...timers]) if (timer.due <= at) { timers.delete(id); timer.fn(); }
    };
    return { requests, written, answers, send, reply, advance, timers };
}

function checks(ShellRequests) {
    // An answered request delivers the shell's reply once and frees its slot.
    let h = harness(ShellRequests);
    const first = h.send();
    assert.deepEqual(h.written, [{ id: 1, kind: "toast", args: ["Title", "Body"] }]);
    assert.equal(h.requests.pending, 1);
    h.reply(1);
    assert.deepEqual(h.answers[first], [{ kind: "answer", answer: "ok", data: null }]);
    assert.equal(h.requests.pending, 0);
    assert.equal(h.timers.size, 0, "an answer clears its deadline");

    // The plan's bound: sixteen await a reply, the seventeenth is busy.
    h = harness(ShellRequests);
    for (let n = 0; n < Protocol.MAX_PENDING_REQUESTS; n++) h.send();
    const extra = h.send();
    assert.deepEqual(h.answers[extra], [{ kind: "busy" }]);
    assert.equal(h.written.length, 16, "a busy request is never written");

    // A timed-out request still awaits its reply: it holds its slot and its
    // late reply is dropped without a second answer.
    h = harness(ShellRequests);
    const late = h.send();
    h.advance(100);
    assert.deepEqual(h.answers[late], [{ kind: "timeout" }]);
    assert.equal(h.requests.pending, 1);
    for (let n = 1; n < Protocol.MAX_PENDING_REQUESTS; n++) h.send();
    assert.deepEqual(h.answers[h.send()], [{ kind: "busy" }], "expired requests count toward the bound");
    h.reply(1);
    assert.deepEqual(h.answers[late], [{ kind: "timeout" }], "a late reply is dropped");
    assert.equal(h.requests.pending, 15);

    // A reply the shell owes no request is a broken peer.
    h = harness(ShellRequests);
    assert.throws(() => h.reply(1), { message: "jarvis: protocol=reply-unknown" });
    h.send();
    h.reply(1);
    assert.throws(() => h.reply(1), { message: "jarvis: protocol=reply-unknown" }, "a second reply");
    h.send("desktop.list", []);
    assert.throws(() => h.reply(2, "toast"), { message: "jarvis: protocol=reply-kind" });

    // A request the judge refuses fails alone and holds no slot.
    h = harness(ShellRequests);
    const refused = h.send("toast", ["Title", "x".repeat(5000)]);
    assert.deepEqual(h.answers[refused], [{ kind: "refused", reason: "jarvis: protocol=request-args" }]);
    assert.equal(h.requests.pending, 0);
    h.send();
    assert.equal(h.written[0].id, 1, "a refused request spends no id");

    // Lease loss releases every deadline and refuses later sends.
    h = harness(ShellRequests);
    h.send();
    h.requests.close();
    assert.equal(h.timers.size, 0);
    assert.throws(() => h.send(), { message: "jarvis: requests=closed" });
}

checks(require(file));
const parent = path.join(tree, "tmp");
fs.mkdirSync(parent, { recursive: true });
const root = fs.mkdtempSync(path.join(parent, "jq-"));
let controls = 0;
try {
    const source = fs.readFileSync(file, "utf8");
    const controlsTable = [
        ["pending-bound", "if (pending.size >= Protocol.MAX_PENDING_REQUESTS) {", "if (false) {"],
        ["expired-dropped", "if (entry.state === \"expired\") return;", ""],
        ["expired-counted", "entry.state = \"expired\";", "entry.state = \"expired\";\n            pending.delete(fields.id);"],
        ["unknown-reply", "if (entry === undefined) throw new Error(\"jarvis: protocol=reply-unknown\");", "if (entry === undefined) return;"],
        ["reply-kind", "if (entry.kind !== message.kind) throw new Error(\"jarvis: protocol=reply-kind\");", ""],
        ["refused-request", "done({ kind: \"refused\", reason: error.message });\n            return;", "return;"],
        ["close-deadlines", "for (const entry of pending.values()) if (entry.timer !== null) clock.clear(entry.timer);", ""]
    ];
    for (const [name, needle, replacement] of controlsTable) {
        assert.equal(source.split(needle).length - 1, 1, name + " mutation match");
        const copy = path.join(root, name + ".js");
        fs.writeFileSync(copy, source.replace(needle, replacement));
        assert.throws(() => checks(require(copy)), assert.AssertionError, name + " must turn red");
        controls++;
    }
} finally { fs.rmSync(root, { recursive: true, force: true }); }
console.log("test-jarvis-requests: ok controls=" + controls);
