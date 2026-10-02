// The local speech row of the chained engine: one sidecar per conversation,
// started from the runtime local setup published, in a private network
// namespace and under the daemon's parent-death signal. Audio's PCM is
// resampled to the models' 16 kHz and each voice's rate back to Audio's.
// Contract: docs/architecture/jarvis-local-speech.md.
"use strict";
const cp = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { PCM_RATE } = require("./Audio.js");

const SIDECAR = path.join(__dirname, "local-speech.py");
const ARTIFACTS = path.join(__dirname, "../artifacts.json");
const MODEL_RATE = 16000;
// The sidecar's frame bounds, both directions.
const HEADER_BYTES = 4096;
const PAYLOAD_BYTES = 64 * 1024;
// Requests written but not yet read by the sidecar: its 120 s utterance bound.
const BACKLOG_BYTES = 120 * MODEL_RATE * 4;
// One sentence's synthesized samples, as received.
const SENTENCE_BYTES = 8 * 1024 * 1024;
// Below Audio's 64 KiB object-mode chunk bound.
const CHUNK_FRAMES = 24000;
// Taps per polyphase branch, and the passband as a fraction of the lower Nyquist rate.
const TAPS = 64;
const PASSBAND = 0.9;
const STDERR_BYTES = 4096;
const RECIPIENTS = Object.freeze([Object.freeze({ kind: "local", provider: "local-speech", account: "" })]);
const CAUSE = /^[a-z-]+(?: [a-z]+=[0-9A-Za-z._-]+)*$/;
// The keys of each sidecar message and whether it carries a payload.
const SHAPES = Object.freeze({
    ready: [["type"], false], final: [["id", "text", "type"], false], audio: [["id", "type"], true],
    spoken: [["id", "rate", "type"], false], failed: [["cause", "type"], false]
});

function failure(cause) { return new Error("jarvis: speech=local-" + cause); }
function unconfigured(cause, detail) { return detail === undefined ? { kind: "unconfigured", cause } : { kind: "unconfigured", cause, detail }; }
function gcd(a, b) { return b === 0 ? a : gcd(b, a % b); }

/**
 * A streaming polyphase resampler: a Blackman-windowed sinc low-pass at the
 * lower rate's band, so decimation folds nothing into the speech band. Output
 * k is the input at time k / to, so a whole stream yields ceil(n * to / from).
 */
class Resampler {
    constructor(from, to) {
        const g = gcd(from, to);
        this.up = to / g;
        this.down = from / g;
        const length = TAPS * this.up;
        const cutoff = PASSBAND * Math.min(from, to) / 2 / (from * this.up);
        const centre = (length - 1) / 2;
        this.h = new Float64Array(length);
        for (let n = 0; n < length; n++) {
            const x = n - centre;
            const ideal = x === 0 ? 2 * cutoff : Math.sin(2 * Math.PI * cutoff * x) / (Math.PI * x);
            const window = 0.42 - 0.5 * Math.cos(2 * Math.PI * n / (length - 1)) + 0.08 * Math.cos(4 * Math.PI * n / (length - 1));
            this.h[n] = ideal * window * this.up;
        }
        this.delay = Math.floor(centre);
        this.buffer = new Float32Array(0);
        this.base = 0;
        this.received = 0;
        this.produced = 0;
    }
    at(i) { return i < 0 || i >= this.received ? 0 : this.buffer[i - this.base]; }
    // Outputs while their newest input sample is below limit, or up to count.
    run(limit, count) {
        const out = [];
        for (;;) {
            if (count !== undefined && this.produced >= count) break;
            const n = this.produced * this.down + this.delay;
            const newest = Math.floor(n / this.up);
            if (count === undefined && newest >= limit) break;
            const phase = n - newest * this.up;
            let y = 0;
            for (let j = 0; j < TAPS; j++) y += this.at(newest - j) * this.h[phase + j * this.up];
            out.push(y);
            this.produced++;
        }
        // The oldest sample the next output reads; never past what arrived.
        const keep = Math.min(this.received, Math.floor((this.produced * this.down + this.delay) / this.up) - TAPS + 1);
        if (keep > this.base) {
            this.buffer = this.buffer.slice(Math.min(keep - this.base, this.buffer.length));
            this.base = keep;
        }
        return Float32Array.from(out);
    }
    push(samples) {
        const joined = new Float32Array(this.buffer.length + samples.length);
        joined.set(this.buffer);
        joined.set(samples, this.buffer.length);
        this.buffer = joined;
        this.received += samples.length;
        return this.run(this.received);
    }
    flush() { return this.run(0, Math.ceil(this.received * this.up / this.down)); }
}

function fromPcm(bytes) {
    const out = new Float32Array(bytes.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = bytes.readInt16LE(2 * i) / 32768;
    return out;
}
function toPcm(samples) {
    const out = Buffer.alloc(samples.length * 2);
    for (let i = 0; i < samples.length; i++)
        out.writeInt16LE(Math.round(Math.max(-1, Math.min(1, samples[i])) * 32767), 2 * i);
    return out;
}
function floats(samples) {
    const out = Buffer.alloc(samples.length * 4);
    for (let i = 0; i < samples.length; i++) out.writeFloatLE(samples[i], 4 * i);
    return out;
}
function encode(header, payload = Buffer.alloc(0)) {
    const head = Buffer.from(JSON.stringify(header), "utf8");
    const prefix = Buffer.alloc(8);
    prefix.writeUInt32BE(head.length, 0);
    prefix.writeUInt32BE(payload.length, 4);
    return Buffer.concat([prefix, head, payload]);
}

/** Frames from the sidecar's stdout; a violation throws its key. */
function reader(receive) {
    let pending = Buffer.alloc(0);
    return chunk => {
        pending = Buffer.concat([pending, chunk]);
        while (pending.length >= 8) {
            const head = pending.readUInt32BE(0), size = pending.readUInt32BE(4);
            if (head === 0 || head > HEADER_BYTES || size > PAYLOAD_BYTES) throw new Error("frame=too-large");
            if (pending.length < 8 + head + size) return;
            let header;
            try { header = JSON.parse(pending.subarray(8, 8 + head).toString("utf8")); }
            catch { throw new Error("header=invalid"); }
            const payload = pending.subarray(8 + head, 8 + head + size);
            pending = pending.subarray(8 + head + size);
            if (header === null || typeof header !== "object" || Array.isArray(header) || !Object.hasOwn(SHAPES, header.type))
                throw new Error("message=invalid");
            const [keys, carries] = SHAPES[header.type];
            const actual = Object.keys(header).sort();
            const expected = header.type === "failed" && Object.hasOwn(header, "id") ? ["cause", "id", "type"] : keys;
            if (actual.join() !== expected.join() || (payload.length !== 0) !== carries)
                throw new Error("message=invalid type=" + header.type);
            receive(header, payload);
        }
    };
}

/**
 * Start one conversation's sidecar. transcribe and speak follow the chained
 * engine's adapter contract; every failure is a keyed speech=local-* error.
 */
function open(state, data) {
    const environment = { LC_ALL: "C.UTF-8" };
    for (const key of ["PATH", "HOME"]) if (process.env[key] !== undefined) environment[key] = process.env[key];
    const child = cp.spawn("unshare", ["--map-current-user", "--net", "--", "setpriv", "--pdeathsig", "KILL", "--",
        path.join(data, "venv/bin/python"), "-I", SIDECAR, "--state", state, "--data", data,
        "--parent", String(process.pid)], { env: environment, stdio: ["pipe", "pipe", "pipe"] });
    // starting: before the sidecar's ready; ended: every request fails with error.
    let life = { kind: "starting" };
    let next = 0;
    let stderr = "";
    const pending = new Map();

    function end(error, abnormal) {
        if (life.kind === "ended") return;
        life = { kind: "ended", error };
        for (const request of pending.values()) request.settle({ kind: "failed", error });
        pending.clear();
        child.stdin.destroy();
        child.kill("SIGKILL");
        if (abnormal && stderr.trim() !== "")
            process.stderr.write("jarvis: speech-sidecar=" + JSON.stringify(stderr.trim()) + "\n");
    }
    function write(header, payload) {
        if (life.kind === "ended") throw life.error;
        child.stdin.write(encode(header, payload));
        if (child.stdin.writableLength > BACKLOG_BYTES) {
            end(failure("backlog"), true);
            throw life.error;
        }
    }
    // An answer for a request this side already settled crossed it; an id
    // never issued is a violation.
    function request(header, kind) {
        if (!Number.isSafeInteger(header.id) || header.id <= 0 || header.id > next) throw new Error("id=invalid");
        const value = pending.get(header.id);
        if (value !== undefined && value.kind !== kind) throw new Error("message=kind type=" + header.type);
        return value;
    }
    const receive = reader((header, payload) => {
        switch (header.type) {
        case "ready":
            if (life.kind !== "starting") throw new Error("ready=repeated");
            life = { kind: "ready" };
            return;
        case "failed": {
            if (typeof header.cause !== "string" || !CAUSE.test(header.cause) || header.cause.length > 120)
                throw new Error("cause=invalid");
            if (!Object.hasOwn(header, "id")) { end(failure(header.cause), false); return; }
            request(header, pending.get(header.id)?.kind)?.settle({ kind: "failed", error: failure(header.cause) });
            return;
        }
        case "final":
            if (typeof header.text !== "string") throw new Error("final=invalid");
            request(header, "utterance")?.settle({ kind: "final", text: header.text });
            return;
        case "audio": {
            if (payload.length % 4 !== 0) throw new Error("audio=partial-sample");
            const speech = request(header, "speech");
            if (speech === undefined) return;
            speech.bytes += payload.length;
            if (speech.bytes > SENTENCE_BYTES) speech.settle({ kind: "failed", error: failure("sentence-audio") });
            else speech.chunks.push(Buffer.from(payload));
            return;
        }
        case "spoken": {
            if (!Number.isSafeInteger(header.rate) || header.rate <= 0 || header.rate > 192000) throw new Error("rate=invalid");
            const speech = request(header, "speech");
            if (speech === undefined) return;
            if (speech.bytes === 0) speech.settle({ kind: "failed", error: failure("synthesis-empty") });
            else speech.settle({ kind: "spoken", rate: header.rate, bytes: Buffer.concat(speech.chunks) });
            return;
        }
        default: throw new Error("message=invalid");
        }
    });
    child.stdout.on("data", chunk => {
        if (life.kind === "ended") return;
        try { receive(chunk); }
        catch (error) { end(failure("protocol " + error.message.replace(/^([a-z-]+)=/, "key=$1 value=")), true); }
    });
    child.stderr.on("data", chunk => { stderr = (stderr + chunk.toString("utf8")).slice(-STDERR_BYTES); });
    child.stdin.on("error", error => end(failure("write code=" + error.code), true));
    child.on("error", error => end(failure("spawn code=" + error.code), true));
    child.on("close", (code, signal) => end(code === 77 ? failure("not-ready")
        : failure("exit code=" + code + " signal=" + signal), true));

    // One pending request; settle runs once and removes it.
    function track(kind, settled) {
        const id = ++next;
        const value = { kind, chunks: [], bytes: 0, settle(outcome) {
            if (pending.get(id) !== value) return;
            pending.delete(id);
            settled(outcome);
        } };
        pending.set(id, value);
        if (life.kind === "ended") value.settle({ kind: "failed", error: life.error });
        return { id, value };
    }
    function sendAudio(id, samples) {
        const step = PAYLOAD_BYTES / 4;
        for (let at = 0; at < samples.length; at += step)
            write({ type: "audio", id }, floats(samples.subarray(at, at + step)));
    }

    return {
        transcribe(frames) {
            let resolve;
            const outcome = new Promise(done => { resolve = done; });
            const { id, value } = track("utterance", resolve);
            const input = frames[Symbol.asyncIterator]();
            // running: sending capture; ended: this side stopped reading frames.
            let sending = { kind: "running" };
            function stop() {
                if (sending.kind === "ended") return;
                sending = { kind: "ended" };
                void input.return?.();
            }
            void outcome.then(stop);
            (async () => {
                const resampler = new Resampler(PCM_RATE, MODEL_RATE);
                let carry = Buffer.alloc(0);
                for (;;) {
                    const step = await input.next();
                    if (sending.kind === "ended") return;
                    if (step.done) break;
                    let bytes = Buffer.concat([carry, step.value.content]);
                    // A read can split a sample; its first byte waits for the next.
                    carry = bytes.subarray(bytes.length - (bytes.length % 2));
                    bytes = bytes.subarray(0, bytes.length - carry.length);
                    sendAudio(id, resampler.push(fromPcm(bytes)));
                }
                // A half sample left when capture ended is not a sample.
                sendAudio(id, resampler.flush());
                write({ type: "end", id });
            })().catch(error => value.settle({ kind: "failed", error }));
            let answered = false;
            return {
                [Symbol.asyncIterator]() { return this; },
                async next() {
                    if (answered) return { value: undefined, done: true };
                    const result = await outcome;
                    answered = true;
                    switch (result.kind) {
                    case "final": return { value: { kind: "final", text: result.text }, done: false };
                    case "failed": throw result.error;
                    case "abandoned": return { value: undefined, done: true };
                    default: throw new Error("jarvis: speech=local-outcome");
                    }
                },
                async return() {
                    if (pending.get(id) === value) {
                        value.settle({ kind: "abandoned" });
                        if (life.kind !== "ended") write({ type: "abort", id });
                    }
                    return { value: undefined, done: true };
                }
            };
        },
        async *speak(sentences) {
            for await (const item of sentences) {
                const text = Buffer.from(item.content, "utf8");
                if (item.content.trim() === "") throw failure("sentence-empty");
                if (text.length > PAYLOAD_BYTES) throw failure("sentence-too-long");
                let resolve;
                const outcome = new Promise(done => { resolve = done; });
                const { id } = track("speech", resolve);
                write({ type: "speak", id }, text);
                const result = await outcome;
                if (result.kind !== "spoken") throw result.error;
                const native = new Float32Array(result.bytes.length / 4);
                for (let i = 0; i < native.length; i++) native[i] = result.bytes.readFloatLE(4 * i);
                const resampler = new Resampler(result.rate, PCM_RATE);
                const pcm = toPcm(result.rate === PCM_RATE ? native : Float32Array.from([...resampler.push(native), ...resampler.flush()]));
                const frames = pcm.length / 2;
                for (let at = 0; at < frames; at += CHUNK_FRAMES) {
                    const chunk = pcm.subarray(2 * at, 2 * Math.min(frames, at + CHUNK_FRAMES));
                    yield at === 0 ? { pcm: chunk, sentence: { text: item.content, frames } } : { pcm: chunk };
                }
            }
        },
        close() { end(failure("closed"), false); }
    };
}

/**
 * Ready when local setup published a marker naming a declared tier for this
 * data root. The sidecar asks setup's readiness judge before it loads, so a
 * stale marker fails the first request with speech=local-not-ready.
 */
function select({ directories }) {
    const state = directories.state;
    const data = path.join(directories.data, "local");
    let marker, root;
    try { marker = JSON.parse(fs.readFileSync(path.join(state, "local-ready.json"), "utf8")); }
    catch (error) {
        if (error.code === "ENOENT") return unconfigured("speech=local-not-set-up");
        return unconfigured("speech=local-not-ready", error.code ?? "marker-json");
    }
    try { root = fs.realpathSync(data); }
    catch (error) { return unconfigured("speech=local-not-ready", error.code); }
    const tiers = JSON.parse(fs.readFileSync(ARTIFACTS, "utf8")).tiers;
    if (marker === null || typeof marker !== "object" || typeof marker.tier !== "string"
            || !Object.hasOwn(tiers, marker.tier) || marker.data !== root)
        return unconfigured("speech=local-not-ready", "marker-stale");
    return { kind: "ready", recipients: RECIPIENTS, open: () => open(state, data) };
}

module.exports = { row: Object.freeze({ select }) };
