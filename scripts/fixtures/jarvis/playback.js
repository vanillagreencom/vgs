// Synthetic PCM and injectable monotonic time. Audio remains the child owner.
"use strict";
const base = require("./audio.js");
const { load } = require("../../../bin/lib/qml-library.js");
const Session = load(base.path.join(base.tree, "shell/plugins/vgs.jarvis/Session.js"));
const { Audio } = require("../../../shell/plugins/vgs.jarvis/backend/Audio.js");

function clock() {
    let at = 0;
    const timers = new Map();
    return {
        now: () => at,
        set: (fn, ms) => { const key = {}; timers.set(key, { fn, at: at + ms }); return key; },
        clear: key => timers.delete(key),
        advance(ms) {
            at += ms;
            for (const [key, timer] of timers) if (timer.at <= at) { timers.delete(key); timer.fn(); }
        },
        timers
    };
}

function setup(source, time = clock(), Implementation = Audio, environment = null) {
    const failures = [], completed = [], writes = [];
    const audio = new Implementation({
        session: Session,
        environment: environment || { PATH: process.env.PATH, HOME: process.env.HOME,
            XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR },
        clock: time, offers: () => {}, level: () => {}, fault: reason => failures.push(reason),
        captureSink: null, playbackSource: () => source
    });
    const state = Session.initial();
    state.gate = { kind: "up" };
    state.playback = { kind: "playing", gen: 1, op: 2, source: 3, interruptible: true,
        admission: { kind: "started" } };
    state.settings = { microphone: "", speaker: "" };
    audio.observe(state);
    audio.devices.speakers = [{ label: "Fixture speaker", value: "fixture.speaker" }];
    const e = { gen: 1, op: 2, source: 3 };
    const start = () => audio.playbackPort.start(e, result => completed.push(result), reason => failures.push(reason));
    const spy = () => {
        const owner = [...audio.children.values()].find(owner => owner.kind === "playback");
        base.assert.ok(owner);
        const write = owner.child.stdin.write.bind(owner.child.stdin);
        owner.child.stdin.write = pcm => {
            writes.push({ at: time.now(), frames: pcm.length / 2 });
            return write(pcm);
        };
        return owner;
    };
    const flush = () => new Promise(resolve => audio.playbackPort.flush({ gen: 1, target: 2 }, resolve));
    return { audio, start, spy, flush, time, completed, failures, writes };
}

async function turn() {
    // Flush promise continuations, not a pacing delay.
    for (let i = 0; i < 4; i++) await new Promise(resolve => setImmediate(resolve));
}

async function finish(promise) {
    let ended = false, error;
    promise.then(() => { ended = true; }, value => { ended = true; error = value; });
    await base.until(() => ended, "playback operation completes");
    if (error !== undefined) throw error;
}

async function control(name, needle, replacement, check) {
    const file = base.path.join(base.tree, "shell/plugins/vgs.jarvis/backend/Audio.js");
    const original = base.fs.readFileSync(file, "utf8");
    base.assert.equal(original.split(needle).length - 1, 1, name + " mutation match");
    const changed = original.replace(needle, replacement);
    base.assert.notEqual(changed, original);
    const folder = base.fs.mkdtempSync(base.path.join(process.env.JARVIS_TEST_ROOT, "playback-mutant-"));
    try {
        base.copyBackend(folder);
        base.fs.writeFileSync(base.path.join(folder, "Audio.js"), changed);
        await base.assert.rejects(() => check(require(base.path.join(folder, "Audio.js")).Audio),
            base.assert.AssertionError, name + " must turn red");
        console.log("control=" + name + " detected");
    } finally { base.fs.rmSync(folder, { recursive: true, force: true }); }
}

module.exports = { ...base, Audio, clock, setup, turn, finish, control };
