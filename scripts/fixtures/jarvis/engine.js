// Scripted speech adapters and a loopback brain for the chained engine, from
// the Jarvis plan § 3.5 adapter contract, Audio's speech-source contract and
// the pinned OpenAI excerpt (jarvis-brain/openai-chat.schema.json), 2026-10-01.
// Synthetic, not recordings. No audio device, provider, account or host
// network: the brain listens on loopback inside the J09 world.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const Check = require("../schema-check.js");
const excerpt = require("../jarvis-brain/openai-chat.schema.json");
const { encode, delta } = require("../jarvis-brain/openai-chat-frames.js");
const tree = path.resolve(__dirname, "../../..");
const plugin = path.join(tree, "shell/plugins/vgs.jarvis");
const WORD_FRAMES = 2400; // 100 ms of 24 kHz PCM per word: synthetic timing.
const CHUNK_FRAMES = 24000; // Below Audio's 64 KiB chunk bound.

// One shared controller per test process. A case resets it before use.
const control = {};
function reset(options = {}) {
    Object.assign(control, { ready: true, recipients: [{ kind: "local", provider: "scripted-speech", account: "" }],
        utterances: [], spoken: [], labels: new Set(), opened: [], closed: 0, aborted: 0, frames: 0, ...options });
}
reset();

// A scripted utterance: partials after successive capture frames, then the
// final once Audio closes the sink. events replaces the scripted sequence.
// afterFrames ends the utterance early, as a provider's turn detection does;
// failAfterClose throws once the capture has closed.
function utterance(final, partials = [], events = null, options = {}) {
    return { final, partials, events, afterFrames: options.afterFrames ?? null, failAfterClose: options.failAfterClose === true };
}

// Alignment at whole words: each word ends WORD_FRAMES after the previous.
function synthesized(text) {
    const words = [...text.matchAll(/\S+/gu)].map((match, index) =>
        ({ frame: (index + 1) * WORD_FRAMES, end: match.index + match[0].length }));
    const frames = words.length * WORD_FRAMES;
    const chunks = [];
    for (let at = 0; at < frames; at += CHUNK_FRAMES) {
        const pcm = Buffer.alloc(Math.min(CHUNK_FRAMES, frames - at) * 2, 0x11);
        chunks.push(at === 0 ? { pcm, sentence: { text, frames, words } } : { pcm });
    }
    return chunks;
}

const row = {
    select() {
        return control.ready ? { kind: "ready", recipients: control.recipients,
            open: ({ net, recipients }) => adapter(net, recipients) }
            : { kind: "unconfigured", cause: "speech=fixture-off" };
    }
};

function adapter(net, recipients) {
    control.opened.push({ net, recipients });
    return {
        // Partials follow successive frames; the final follows the last
        // frame. A return() before the final is counted as abandoned.
        transcribe(frames) {
            const script = control.utterances.shift();
            assert.ok(script, "a scripted utterance exists for each capture");
            const events = script.events ?? [...script.partials.map((text, index) => ({ kind: "partial", text, rev: index + 1 })),
                { kind: "final", text: script.final }];
            const input = frames[Symbol.asyncIterator]();
            let index = 0;
            let ended = false;
            let counted = 0;
            const take = frame => {
                counted++;
                control.frames += frame.content.length;
                for (const label of frame.labels) control.labels.add(label);
            };
            return { [Symbol.asyncIterator]() { return this; },
                async next() {
                    if (ended || index >= events.length) return { value: undefined, done: true };
                    if (index < events.length - 1) {
                        const frame = await input.next();
                        if (!frame.done) {
                            take(frame.value);
                            return { value: events[index++], done: false };
                        }
                        index = events.length - 1;
                    }
                    while (script.afterFrames === null || counted < script.afterFrames) {
                        const frame = await input.next();
                        if (frame.done) break;
                        take(frame.value);
                    }
                    if (ended) return { value: undefined, done: true };
                    if (script.failAfterClose) throw new Error("jarvis: speech=fixture-failed");
                    return { value: events[index++], done: false };
                },
                async return() {
                    if (!ended && index < events.length) control.aborted++;
                    ended = true;
                    await input.return?.();
                    return { value: undefined, done: true };
                } };
        },
        async *speak(sentences) {
            for await (const sentence of sentences) {
                control.spoken.push(sentence.content);
                for (const label of sentence.labels) control.labels.add(label);
                yield* synthesized(sentence.content);
            }
        },
        close() { control.closed++; }
    };
}

// A disposable plugin copy whose speech table holds the scripted row. Extra
// edits plant one defect each; every edit asserts its single match.
function copy(root, edits = []) {
    const folder = fs.mkdtempSync(path.join(root, "engine-"));
    fs.cpSync(path.join(plugin, "backend"), path.join(folder, "backend"), { recursive: true });
    for (const name of ["AccountProviders.js", "Session.js", "JarvisProtocol.js"])
        fs.copyFileSync(path.join(plugin, name), path.join(folder, name));
    const file = path.join(folder, "backend/ChainedEngine.js");
    const source = fs.readFileSync(file, "utf8");
    let changed = source;
    for (const [needle, replacement] of [["const SPEECH = Object.freeze({});",
        "const SPEECH = Object.freeze({ scripted: require(" + JSON.stringify(__filename) + ").row });"], ...edits]) {
        assert.equal(changed.split(needle).length - 1, 1, "engine instrumentation match: " + needle.slice(0, 60));
        changed = changed.replace(needle, replacement);
    }
    assert.notEqual(changed, source);
    fs.writeFileSync(file, changed);
    return { folder, Engine: require(file) };
}

// The OpenAI-compatible brain on a loopback port. Each request takes the next
// reply; every body is read whole and checked against the pinned excerpt.
// A reply is a list of frames; {wait: promise} pauses the stream.
function brain(port) {
    // One close observation per connection; keep-alive serves several requests.
    const closes = new WeakMap();
    const closing = socket => {
        if (!closes.has(socket)) closes.set(socket, new Promise(resolve => socket.once("close", resolve)));
        return closes.get(socket);
    };
    const requests = [];
    const faults = [];
    // A request waits for its case to queue the reply it should receive. A
    // request whose client went away takes none, so it cannot steal one.
    let waiters = [];
    const wake = () => { const current = waiters; waiters = []; for (const resolve of current) resolve(); };
    const replies = [];
    const push = replies.push.bind(replies);
    replies.push = (...values) => { const count = push(...values); wake(); return count; };
    const reply = async socket => {
        socket.once("close", wake);
        while (replies.length === 0 && !socket.destroyed) await new Promise(resolve => waiters.push(resolve));
        socket.removeListener("close", wake);
        return socket.destroyed ? null : replies.shift();
    };
    const server = http.createServer(async (request, response) => {
        const record = { body: null, closed: closing(request.socket) };
        requests.push(record);
        try {
            const chunks = [];
            for await (const chunk of request) chunks.push(chunk);
            record.body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
            const problems = Check.errors(excerpt, "CreateChatCompletionRequest", record.body);
            if (problems.length) throw new Error("request " + problems.join("; "));
            const frames = await reply(request.socket);
            if (frames === null) return;
            response.writeHead(200, { "content-type": "text/event-stream" });
            for (const frame of frames) {
                if (frame !== null && typeof frame === "object" && Object.hasOwn(frame, "wait")) {
                    await frame.wait;
                    // A client that cancelled during the wait gets nothing more.
                    if (request.socket.destroyed) return;
                } else response.write(encode(frame, "engine"));
            }
            response.end();
        } catch (error) {
            faults.push(error.message);
            response.destroy();
        }
    });
    const ready = new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, "127.0.0.1", resolve);
    });
    return { ready, requests, replies, faults,
        close: () => new Promise(resolve => server.close(resolve)), closeAll: () => server.closeAllConnections() };
}

// Reply builders over the pinned frame shape.
function text(...parts) {
    return [delta({ role: "assistant", content: "" }), ...parts.map(part => typeof part === "string"
        ? delta({ content: part }) : part), delta({}, "stop"), "[DONE]"];
}
function calls(...values) {
    return [delta({ role: "assistant", content: null }), ...values.map((value, index) => delta({ tool_calls: [{ index, id: value.id,
        type: "function", function: { name: value.name, arguments: JSON.stringify(value.arguments) } }] })),
    delta({}, "tool_calls"), "[DONE]"];
}

module.exports = { control, reset, utterance, synthesized, row, copy, brain, text, calls, WORD_FRAMES };
