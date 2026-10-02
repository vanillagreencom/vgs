// Private scripted ports for the v1 Session effect contract, 2026-09-30.
// No audio, provider, socket or tool runs. File gates advance callbacks only.
// The duplex speech port, 2026-10-01, emits one caption per transcript gate
// through the callbacks of the session it opened, live or closed. A
// hold-flush file holds the flush acknowledgement until the flush gate.
// With the chained plan installed in the engine copy, 2026-10-02, the brain
// port hands each turn to the daemon's real chained engine. Its scripted
// driver answers one reply per reply gate, so the words the bubble draws are
// the sentences the engine released and captioned.
"use strict";
const fs = require("node:fs");
const path = require("node:path");

// Longer than the bubble's three lines at its widest card.
const REPLY = Array(24).fill("scripted reply").join(" ");
// One gate table per daemon; the chained driver waits on the same gates.
let gates = null;
// Set once the engine copy selects the chained plan.
let chained = false;

function ports(root, engine) {
    fs.mkdirSync(root, { recursive: true });
    const waiting = new Map();
    let collect = null;
    const record = (kind, values) => fs.appendFileSync(path.join(root, "effects.jsonl"),
        JSON.stringify({ ...values, kind }) + "\n");
    const wait = (gate, done) => waiting.set(gate, done);
    gates = { wait, drop: gate => waiting.delete(gate) };
    const timer = setInterval(() => {
        for (const [gate, done] of waiting) {
            const file = path.join(root, gate);
            if (!fs.existsSync(file)) continue;
            fs.unlinkSync(file);
            waiting.delete(gate);
            done();
        }
        const final = path.join(root, "final");
        if (collect !== null && fs.existsSync(final)) {
            fs.unlinkSync(final);
            const done = collect;
            collect = null;
            done("final", "scripted utterance");
        }
    }, 10); // Poll explicit gates, not a simulated provider latency.
    timer.unref();
    process.stdin.once("end", () => clearInterval(timer));
    return {
        capture: {
            open: (e, done) => { record("capture-open", e); done(); },
            collect: (e, done) => { record("collect", e); collect = done; },
            close: (e, done) => {
                record("capture-close", e);
                const final = collect;
                collect = null;
                const finish = () => { done(); if (final !== null) final("final", "scripted utterance"); };
                if (fs.existsSync(path.join(root, "hold-close"))) wait("close", finish);
                else finish();
            }
        },
        brain: {
            send: (e, done) => {
                record("brain-send", e);
                if (chained) { engine.brain.send(e, done); return; }
                wait("brain", () => {
                    record("brain-callback", e);
                    done("play", { interruptible: true }); done("brain-done");
                });
            },
            cancel: (e, done) => {
                record("brain-cancel", e);
                if (chained) { engine.brain.cancel(e, done); return; }
                const late = waiting.get("brain");
                waiting.delete("brain");
                if (late !== undefined) wait("late-brain", late);
                done();
            },
            close: e => {
                record("brain-close", e);
                if (chained) engine.brain.close(e);
                else waiting.delete("brain");
            },
            outcome: () => { throw new Error("scripted: unexpected-tool"); }
        },
        playback: {
            start: (e, done) => {
                record("playback-start", e);
                wait("played", () => { record("playback-callback", e); done(); });
            },
            flush: (e, done) => {
                record("playback-flush", e);
                const late = waiting.get("played");
                waiting.delete("played");
                if (late !== undefined) wait("late-played", late);
                if (fs.existsSync(path.join(root, "hold-flush"))) wait("flush", done);
                else done();
            }
        },
        tools: {
            start: () => { throw new Error("scripted: unexpected-tool"); },
            cancel: () => { throw new Error("scripted: unexpected-tool"); },
            outcome: () => { throw new Error("scripted: unexpected-tool"); },
            sync: () => {}, close: () => {}
        },
        approval: {
            show: () => { throw new Error("scripted: unexpected-approval"); },
            end: () => { throw new Error("scripted: unexpected-approval"); },
            refused: () => { throw new Error("scripted: unexpected-approval"); }
        },
        speech: {
            open: (e, events) => {
                record("speech-open", e);
                const caption = () => {
                    events.transcript({ role: "user", text: "scripted words", stage: "partial", rev: 1 });
                    wait("transcript", caption);
                };
                wait("transcript", caption);
            },
            close: e => record("speech-close", e),
            flush: e => record("speech-flush", e),
            release: () => {}
        }
    };
}

// The chained plan: local recipients, a speech row that consumes released
// sentences and plays nothing (the scripted playback port stands in for
// Audio), and the scripted driver. The engine's own transfer, release, audit,
// Speakable and caption steps run unchanged.
function plan() {
    chained = true;
    return { kind: "ready",
        speech: { recipients: [{ kind: "local", provider: "scripted-speech", account: "" }],
            open: () => ({
                transcribe() { throw new Error("scripted: unexpected-transcription"); },
                async *speak(sentences) { for await (const sentence of sentences) void sentence; },
                close() {}
            }) },
        brain: { provider: { id: "scripted", driver: "scripted" }, model: "", account: null, key: null,
            recipient: { kind: "local", provider: "scripted-brain", account: "" },
            guidance: { instructions: "", afterToolResult: null } } };
}

// The wire brain's driver surface. Each response waits for the reply gate,
// then streams REPLY and stops; cancel or close ends a waiting response.
const driver = { create() {
    let pending = null;
    // Only a waiting response holds the reply gate.
    const end = () => {
        if (pending === null) return Promise.resolve();
        gates.drop("reply");
        const resolve = pending;
        pending = null;
        resolve?.({ value: undefined, done: true });
        return Promise.resolve();
    };
    return {
        start() {},
        // As WireBrain does, the request releases its items' labels.
        send(request) {
            const labels = [...new Set(request.items.flatMap(item => item.labels))];
            const steps = [{ kind: "text", text: REPLY }, { kind: "done", reason: "stop" }];
            let opened = false;
            const events = { [Symbol.asyncIterator]() { return { next() {
                if (opened) return Promise.resolve(steps.length ? { value: steps.shift(), done: false } : { value: undefined, done: true });
                return new Promise(resolve => {
                    pending = resolve;
                    gates.wait("reply", () => {
                        opened = true;
                        pending = null;
                        resolve({ value: steps.shift(), done: false });
                    });
                });
            } }; } };
            return { release: { needed: [], withheld: [], labels }, events };
        },
        record() {},
        cancel: end,
        close() { void end(); }
    };
} };

// Install only in a disposable daemon. The installed product has no fixture
// option, environment switch or import into scripts/.
function instrument(file, root, engine = "chained", mappedIndicator = false) {
    const changes = [
        ['engine: "chained",', "engine: " + JSON.stringify(engine) + ","],
        ['audio.playbackSource = engine.playbackSource;',
            'audio.playbackSource = engine.playbackSource;\n                    const scripted = require("./scripted-fixture.js").ports(' + JSON.stringify(root) + ', engine);\n' +
            '                    runner.ports.speech = scripted.speech;\n' +
            '                    Object.assign(runner.ports, { capture: scripted.capture, brain: scripted.brain, playback: scripted.playback });'],
        ['configured: configuration.kind === "ready", settings: context.settings',
            'configured: true, settings: context.settings']
    ];
    if (!mappedIndicator) changes.push(
        ['runner.dispatch({ type: "snapshot", locked: context.locked,',
            'runner.dispatch({ type: "indicator", shown: true });\n                runner.dispatch({ type: "snapshot", locked: context.locked,']);
    edit(file, changes);
    fs.copyFileSync(__filename, path.join(path.dirname(file), "scripted-fixture.js"));
}

// Replace each needle once, asserting its single match, in a plain file.
function edit(file, changes) {
    if (fs.lstatSync(file).isSymbolicLink()) throw new Error("scripted: symlink=" + file);
    const source = fs.readFileSync(file, "utf8");
    let changed = source;
    for (const [needle, value] of changes) {
        if (changed.split(needle).length !== 2) throw new Error("scripted: instrumentation-match=" + needle);
        changed = changed.replace(needle, value);
    }
    if (changed === source) throw new Error("scripted: unchanged");
    fs.writeFileSync(file, changed);
}

// Select the chained plan in a disposable engine copy beside an instrumented
// daemon, whose scripted-fixture.js it loads.
function chainedEngine(file) {
    if (!fs.existsSync(path.join(path.dirname(file), "scripted-fixture.js"))) throw new Error("scripted: daemon-uninstrumented");
    edit(file, [
        ["plan = select(settings, accounts);", 'plan = require("./scripted-fixture.js").plan();'],
        ['const DRIVERS = Object.freeze({ "openai-chat": OpenAIChat,',
            'const DRIVERS = Object.freeze({ scripted: require("./scripted-fixture.js").driver, "openai-chat": OpenAIChat,']
    ]);
}

module.exports = { ports, instrument, plan, driver, chainedEngine };
if (require.main === module) {
    if (process.argv.length === 4 && process.argv[2] === "--chained-engine") chainedEngine(process.argv[3]);
    else if (process.argv.length === 4 || (process.argv.length === 5 && process.argv[4] === "--mapped-indicator"))
        instrument(process.argv[2], process.argv[3], "chained", process.argv[4] === "--mapped-indicator");
    else throw new Error("scripted: arguments");
}
