#!/usr/bin/env node
// Production playback ports, private synthetic pw-cat and a manual clock.
"use strict";
const { assert, fs, path, world, until, Audio, setup, turn, finish, control } = require("./fixtures/jarvis/playback.js");
const { Readable, PassThrough } = require("node:stream");

async function ready(w) {
    await until(() => w.audio.playback !== null && w.audio.playback.kind === "feeding", "playback feeding");
    return w.spy();
}

async function pacing(Implementation = Audio) {
    const source = new PassThrough();
    const w = setup(source, undefined, Implementation);
    const running = w.start();
    try {
        await ready(w);
        source.write(Buffer.alloc(24000));
        await turn();
        assert.equal(w.audio.playback.written, 1440, "only 60 ms may be submitted at time zero");
        assert.equal(w.time.timers.size, 1);
        w.time.advance(19);
        await turn();
        assert.equal(w.audio.playback.written, 1440);
        w.time.advance(1);
        await turn();
        assert.equal(w.audio.playback.written, 1920, "one 20 ms packet after its deadline");
        w.time.advance(980);
        await turn();
        assert.equal(w.audio.playback.written, 3360, "a late event loop cannot send a catch-up burst");
        const before = w.writes.length;
        await w.flush();
        assert.equal(w.time.timers.size, 0, "flush removes the pacing timer");
        w.time.advance(5000);
        await turn();
        assert.equal(w.writes.length, before, "no write follows interruption");
        await finish(running);
        assert.equal(source.destroyed, true);
        assert.deepEqual(w.failures, []);
        assert.deepEqual(w.completed, []);
    } finally { await w.audio.close("test-end"); }
}

async function accounting(Implementation = Audio) {
    const source = new PassThrough({ objectMode: true, highWaterMark: 1 });
    const w = setup(source, undefined, Implementation);
    const running = w.start();
    try {
        await ready(w);
        source.write({ pcm: Buffer.alloc(9600), sentence: { text: "one two three", frames: 4800,
            words: [{ frame: 960, end: 3 }, { frame: 1920, end: 7 }, { frame: 4800, end: 13 }] } });
        await turn();
        assert.deepEqual(w.audio.playbackResult(w.audio.playback), {
            gen: 1, op: 2, source: 3, writtenFrames: 1440, heardFrames: 0, heardText: ""
        });
        for (let i = 0; i < 4; i++) { w.time.advance(20); await turn(); }
        assert.equal(w.audio.playback.written, 3360);
        const result = await w.flush();
        assert.deepEqual(result, { gen: 1, op: 2, source: 3,
            writtenFrames: 3360, heardFrames: 1440, heardText: "one" },
        "subtract both lead and node latency, then round down to a complete aligned word");
        assert.equal(Object.isFrozen(result), true);
        w.time.advance(10000);
        assert.equal(result.heardText, "one", "the interruption report cannot grow during teardown");
        await finish(running);
    } finally { await w.audio.close("test-end"); }
}

async function completion(Implementation = Audio) {
    for (const structured of [false, true]) {
        const source = new PassThrough(structured ? { objectMode: true, highWaterMark: 1 } : {});
        const w = setup(source, undefined, Implementation);
        const run = async () => {
            const running = w.start();
            await ready(w);
            source.end(structured ? { pcm: Buffer.alloc(5760),
                sentence: { text: "whole sentence", frames: 2880 } } : Buffer.alloc(5760));
            await turn();
            assert.equal(w.audio.playbackResult(w.audio.playback).heardText, "",
                "sentence sample counts alone cannot identify a partial word");
            for (let i = 0; i < 3; i++) { w.time.advance(20); await turn(); }
            await finish(running);
            assert.equal(w.completed.length, 1);
            assert.equal(w.completed[0].writtenFrames, 2880);
            assert.equal(w.completed[0].heardFrames, 960);
            assert.equal(w.completed[0].heardText, "");
            assert.deepEqual(w.failures, []);
            assert.equal(w.audio.playback, null);
        };
        try { await run(); } finally { await w.audio.close("test-end"); }
    }
}

async function sentenceAccounting() {
    const source = new PassThrough({ objectMode: true, highWaterMark: 1 });
    const w = setup(source);
    const running = w.start();
    try {
        await ready(w);
        source.write({ pcm: Buffer.alloc(480), sentence: { text: "first sentence.", frames: 240 } });
        source.write({ pcm: Buffer.alloc(5760), sentence: { text: "next sentence.", frames: 2880 } });
        await turn();
        assert.equal(w.audio.playbackResult(w.audio.playback).heardText, "");
        for (let i = 0; i < 3; i++) { w.time.advance(20); await turn(); }
        const result = await w.flush();
        assert.equal(result.heardText, "first sentence.", "only the completed sentence has known timing");
        await finish(running);
    } finally { await w.audio.close("test-end"); }
}

async function startup(Implementation = Audio) {
    const source = new PassThrough();
    const w = setup(source, undefined, Implementation);
    const running = w.start();
    try {
        await w.flush();
        await finish(running);
        assert.equal(w.audio.children.size, 0, "immediate interrupt retires pre-child startup");
        assert.deepEqual(w.failures, []);
        assert.deepEqual(w.completed, []);
    } finally { await w.audio.close("test-end"); }
}

async function awaitingInput() {
    const source = new PassThrough();
    const w = setup(source);
    const running = w.start();
    try {
        await ready(w);
        await turn();
        assert.notEqual(w.audio.playback.wake, null);
        await w.flush();
        await finish(running);
        assert.equal(source.listenerCount("readable"), 0);
        assert.equal(source.listenerCount("end"), 0);
        assert.equal(source.listenerCount("close"), 0);
        assert.equal(source.destroyed, true);
    } finally { await w.audio.close("test-end"); }
}

async function backpressure(Implementation = Audio) {
    let pulled = 0;
    const source = new Readable({ objectMode: true, highWaterMark: 1,
        read() { pulled++; this.push({ pcm: Buffer.alloc(65536) }); } });
    const w = setup(source, undefined, Implementation);
    const running = w.start();
    try {
        await ready(w);
        await turn();
        assert.ok(pulled <= 2, "pacing propagates backpressure instead of collecting every provider frame");
        assert.equal(w.audio.playback.written, 1440);
        await w.flush();
        await finish(running);
        assert.equal(source.destroyed, true);
    } finally { await w.audio.close("test-end"); }
}

async function drain() {
    const marker = path.join(process.env.HOME, "playback-blocks");
    fs.writeFileSync(marker, "");
    const source = new Readable({ highWaterMark: 65536, read() { this.push(Buffer.alloc(65536)); } });
    const w = setup(source);
    const running = w.start();
    try {
        const owner = await ready(w);
        for (let i = 0; i < 1500 && !owner.child.stdin.writableNeedDrain; i++) {
            w.time.advance(20);
            await turn();
        }
        assert.equal(owner.child.stdin.writableNeedDrain, true, "reach actual child-pipe backpressure");
        assert.equal(w.time.timers.size, 0, "the pump waits on drain, not on the clock");
        assert.ok(source.readableLength <= 65536);
        await w.flush();
        await finish(running);
        assert.equal(owner.child.stdin.listenerCount("drain"), 0);
        assert.equal(source.destroyed, true);
    } finally {
        await w.audio.close("test-end");
        fs.unlinkSync(marker);
    }
}

async function failureCase(value, reason, Implementation = Audio, options = {}) {
    const source = options.readableOnly
        ? new Readable({ objectMode: !options.byte, highWaterMark: options.highWaterMark, read() {} })
        : new PassThrough({ objectMode: true, highWaterMark: 1, ...options });
    const w = setup(source, undefined, Implementation);
    const running = w.start();
    try {
        // An invalid source's high-water mark fails before acquisition.
        if (options.highWaterMark === undefined && options.writableHighWaterMark === undefined) await ready(w);
        if (options.readableOnly) { source.push(value); source.push(null); }
        else source.end(value);
        await until(() => w.failures.length !== 0, reason + " reaches the failure callback");
        await finish(running);
        assert.deepEqual(w.failures, [reason]);
        assert.equal(source.destroyed, true);
        assert.equal(w.audio.children.size, 0);
        assert.deepEqual(w.completed, []);
    } finally { await w.audio.close("test-end"); }
}

async function failures() {
    for (const [packet, reason] of [
        [{ pcm: "not PCM" }, "playback-frame"],
        [{ pcm: Buffer.alloc(1) }, "playback-frame"],
        [{ pcm: Buffer.alloc(65538) }, "playback-frame"],
        [{ pcm: Buffer.alloc(480), sentence: { text: "one", frames: 239 } }, "playback-sentence"],
        [{ pcm: Buffer.alloc(480), sentence: { text: "one", frames: 720001 } }, "playback-sentence"],
        [{ pcm: Buffer.alloc(480), sentence: { text: "one two", frames: 240,
            words: [{ frame: 120, end: 2 }, { frame: 240, end: 7 }] } }, "playback-words"],
        [{ pcm: Buffer.alloc(480), sentence: { text: "one two", frames: 240,
            words: [{ frame: 120, end: 3 }] } }, "playback-words"],
        [{ pcm: Buffer.alloc(480), sentence: { text: "one", frames: 240, words: [null] } }, "playback-words"],
        [{ pcm: Buffer.alloc(480), sentence: { text: "one", frames: 480 } }, "playback-sentence-incomplete"],
        [{ pcm: Buffer.alloc(480), sentence: { text: "x".repeat(65537), frames: 240 } },
            "playback-transcript-overflow"]
    ]) await failureCase(packet, reason);
    await failureCase({ pcm: Buffer.alloc(480) }, "playback-source-buffer", Audio, { highWaterMark: 30 });
    await failureCase(Buffer.alloc(1440002), "playback-source-buffer", Audio,
        { highWaterMark: 1, readableOnly: true, byte: true });
    const words = Array.from({ length: 4097 }, (_, i) => ({ frame: i + 1, end: (i + 1) * 5 }));
    await failureCase({ pcm: Buffer.alloc(8194),
        sentence: { text: "word ".repeat(4097), frames: 4097, words } }, "playback-words");
    for (const phase of ["starting", "feeding"]) {
        const source = new PassThrough();
        const w = setup(source);
        const running = w.start();
        try {
            if (phase === "feeding") await ready(w);
            else await until(() => w.audio.children.size !== 0, "source acquired during startup");
            source.destroy(new Error("provider disconnected"));
            await finish(running);
            await until(() => w.failures.length === 1, "provider failure acknowledgment");
            assert.deepEqual(w.failures, ["playback-source: provider disconnected"]);
            assert.equal(w.audio.children.size, 0);
            assert.deepEqual(w.completed, []);
        } finally { await w.audio.close("test-end"); }
    }
}

async function successive() {
    const sources = [new PassThrough(), new PassThrough()];
    const w = setup(sources[0]);
    try {
        const first = w.start();
        await ready(w);
        sources[0].write(Buffer.alloc(2400));
        await turn();
        await w.flush();
        await finish(first);
        w.audio.playbackSource = () => sources[1];
        const second = w.start();
        await ready(w);
        sources[0].emit("error", new Error("late old source"));
        sources[1].write(Buffer.alloc(480));
        await turn();
        assert.equal(w.audio.playback.written, 240, "a new operation starts its own frame account");
        assert.deepEqual(w.failures, []);
        await w.flush();
        await finish(second);
    } finally { await w.audio.close("test-end"); }
}

async function factoryInterruption() {
    const source = new PassThrough();
    const w = setup(source);
    w.audio.playbackSource = () => { void w.flush(); return source; };
    try {
        await finish(w.start());
        await w.audio.release;
        assert.equal(source.destroyed, true, "a source acquired during a synchronous interruption is released");
        assert.equal(w.audio.children.size, 0);
        assert.equal(w.audio.playbackFeed, null);
    } finally { await w.audio.close("test-end"); }
}

async function inside() {
    for (const test of [pacing, accounting, completion, sentenceAccounting, startup, awaitingInput, backpressure, drain,
        failures, successive, factoryInterruption]) {
        console.log("case=" + test.name);
        await test();
    }
    await control("pace", "const PLAYBACK_LEAD_MS = 60;", "const PLAYBACK_LEAD_MS = 600;", pacing);
    await control("no-catch-up", "Math.max(playback.frontier === null ? now : playback.frontier, now)",
        "(playback.frontier === null ? now : playback.frontier)", pacing);
    await control("heard-written", "playback.written - Math.ceil(", "playback.received - Math.ceil(", accounting);
    await control("heard-lead", "(PLAYBACK_LEAD_MS + NODE_LATENCY_MS)", "(0 + NODE_LATENCY_MS)", accounting);
    await control("heard-node-latency", "(PLAYBACK_LEAD_MS + NODE_LATENCY_MS)", "(PLAYBACK_LEAD_MS + 0)", accounting);
    await control("word-boundary", "playback.text.slice(0, end).trimEnd()", "playback.text.trimEnd()", accounting);
    await control("waiter-flush", "if (this.playback.wake !== null) this.playback.wake();",
        "if (false && this.playback.wake !== null) this.playback.wake();", pacing);
    await control("source-bound", "source.readableHighWaterMark > queueLimit",
        "false && source.readableHighWaterMark > queueLimit",
        impl => failureCase({ pcm: Buffer.alloc(480) }, "playback-source-buffer", impl,
            { highWaterMark: 30, readableOnly: true }));
    await control("duplex-source-bound", "source.writableHighWaterMark > queueLimit",
        "false && source.writableHighWaterMark > queueLimit",
        impl => failureCase({ pcm: Buffer.alloc(480) }, "playback-source-buffer", impl,
            { readableHighWaterMark: 1, writableHighWaterMark: 30 }));
    await control("pending-source-bound", "source.readableLength > queueAllowance",
        "false && source.readableLength > queueAllowance",
        impl => failureCase(Buffer.alloc(1440002), "playback-source-buffer", impl,
            { highWaterMark: 1, readableOnly: true, byte: true }));
    await control("pcm-bound", "pcm.length > BUFFER_BYTES || pcm.length % 2 !== 0",
        "false && pcm.length > BUFFER_BYTES || pcm.length % 2 !== 0",
        impl => failureCase({ pcm: Buffer.alloc(65538) }, "playback-frame", impl));
    await control("pcm-alignment", "pcm.length % 2 !== 0", "false && pcm.length % 2 !== 0",
        impl => failureCase({ pcm: Buffer.alloc(1) }, "playback-frame", impl));
    await control("sentence-bound", "sentence.frames > PCM_RATE * 30", "false && sentence.frames > PCM_RATE * 30",
        impl => failureCase({ pcm: Buffer.alloc(480), sentence: { text: "one", frames: 720001 } }, "playback-sentence", impl));
    await control("sentence-complete", "if (playback.received < playback.sentenceEnd)",
        "if (false && playback.received < playback.sentenceEnd)",
        impl => failureCase({ pcm: Buffer.alloc(480), sentence: { text: "one", frames: 480 } },
            "playback-sentence-incomplete", impl));
    await control("transcript-bound", "Buffer.byteLength(playback.text + separator + sentence.text) > TRANSCRIPT_BYTES",
        "false && Buffer.byteLength(playback.text + separator + sentence.text) > TRANSCRIPT_BYTES",
        impl => failureCase({ pcm: Buffer.alloc(480), sentence: { text: "x".repeat(65537), frames: 240 } },
            "playback-transcript-overflow", impl));
    await control("alignment-bound", "playback.words.length + words.length > 4096",
        "false && playback.words.length + words.length > 4096", impl =>
            failureCase({ pcm: Buffer.alloc(8194), sentence: { text: "word ".repeat(4097), frames: 4097,
                words: Array.from({ length: 4097 }, (_, i) => ({ frame: i + 1, end: (i + 1) * 5 })) } },
            "playback-words", impl));
    await control("alignment-complete", "if (frame !== sentence.frames || end !== sentence.text.length)",
        "if (false && (frame !== sentence.frames || end !== sentence.text.length))",
        impl => failureCase({ pcm: Buffer.alloc(480), sentence: { text: "one two", frames: 240,
            words: [{ frame: 120, end: 3 }] } }, "playback-words", impl));
    await control("natural-completion", "owner.child.stdin.end();", "if (false) owner.child.stdin.end();", completion);
    await control("startup-flush", "this.playback = null;\n            if (this.playbackFeed !== null)",
        "if (false) this.playback = null;\n            if (this.playbackFeed !== null)", startup);
    console.log("test-jarvis-playback: ok controls=19 lead_frames=1440 node_frames=480");
}

world(inside).catch(error => { console.error(error); process.exitCode = 1; });
