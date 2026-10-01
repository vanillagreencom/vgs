// The GPT-Live duplex speech engine: one provider session per conversation,
// its input and output audio and its captions. Session owns the lifetime
// through the speech port; Audio owns devices and calls captureSink and
// playbackSource. Contract and pinned protocol: docs/architecture/jarvis-live.md.
"use strict";
const { Readable, Writable } = require("node:stream");
const Policy = require("./Policy.js");
const Providers = require("./Providers.js");
const Net = require("./net.js");
const Guidance = require("./Guidance.js");
const { sourceLimit, PCM_RATE } = require("./Audio.js");

const MODEL = "gpt-live-1";
const FORMAT = Object.freeze({ type: "audio/pcm", rate: PCM_RATE });
// Recovery bounds and grouping rules, not measured latency budgets.
const IDLE_MS = 60000;            // plan § 3.5
const START_WAIT_MS = 20000;      // connect and session.started
const CLOSE_WAIT_MS = 15000;      // session.close to session.closed, as the vendor's example waits
const REPLY_GAP_MS = 500;         // no output for this long ends a playing reply
const SILENCE_TICK_MS = 100;
const SILENCE_MAX_MS = 1000;      // no catch-up past this after a stalled event loop
const SEGMENT_GAP_MS = 1200;      // a speaker's pause on the session timeline ends a caption
const PENDING_BYTES = PCM_RATE * 2 * START_WAIT_MS / 1000;
const APPEND_BYTES = PCM_RATE * 2;
const SEND_BACKLOG_BYTES = 256 * 1024;
const FRAME_CHARS = 1024 * 1024;
const FINALIZING = 4;
const REPLY_BYTES = sourceLimit(false, false);
const CLOSED_REASONS = ["close_requested", "expired", "content", "remote_hangup", "connection_lost"];
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

function fail(code) { throw new Error("jarvis: live=" + code); }
function plain(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function time(value) { return typeof value === "number" && Number.isFinite(value) && value >= 0; }
// Provider codes and types are reported; provider message text is not.
function token(value) { return typeof value === "string" && /^[A-Za-z0-9_.-]{1,64}$/.test(value) ? value : "unrecognized"; }
function reasonOf(error) { return String(error.message).replace(/^jarvis: /, "").slice(0, 160); }

/**
 * The one narrowing door for a server message. Returns a tagged event or
 * throws a keyed error. Types the session never requests, delegation included,
 * refuse: J36 configures client delegation and does not serve it.
 */
function eventOf(data) {
    if (typeof data !== "string") fail("frame-binary");
    if (data.length > FRAME_CHARS) fail("frame-size");
    let value;
    try { value = JSON.parse(data); } catch { fail("frame-json"); }
    if (!plain(value) || typeof value.type !== "string") fail("frame-shape");
    switch (value.type) {
    case "session.started": {
        const session = value.session;
        if (!plain(session) || typeof session.id !== "string" || session.id === "") fail("frame-shape");
        const format = plain(session.audio) ? session.audio.format : undefined;
        if (format !== undefined && (!plain(format) || format.type !== FORMAT.type || format.rate !== FORMAT.rate))
            fail("format");
        return { kind: "started" };
    }
    case "session.output_audio.delta": {
        if (typeof value.delta !== "string" || !BASE64.test(value.delta)) fail("output-audio");
        const pcm = Buffer.from(value.delta, "base64");
        if (pcm.length % 2 !== 0) fail("output-audio");
        return { kind: "audio", pcm };
    }
    case "session.input_transcript.delta":
    case "session.output_transcript.delta":
        if (typeof value.delta !== "string" || !time(value.start_ms) || !time(value.end_ms) || value.end_ms < value.start_ms)
            fail("frame-shape");
        return { kind: "caption", role: value.type === "session.input_transcript.delta" ? "user" : "assistant",
            text: value.delta, start: value.start_ms, end: value.end_ms };
    case "session.usage.updated":
        if (!plain(value.usage) || !time(value.usage.seconds)) fail("frame-shape");
        return { kind: "ignored" };
    case "info":
        return { kind: "ignored" };
    case "session.closed":
        if (!CLOSED_REASONS.includes(value.reason)) fail("frame-shape");
        return { kind: "closed", reason: value.reason };
    case "session.delegation.created":
        return fail("delegation-unsupported");
    case "error":
        return fail("server-error code=" + token(plain(value.error) ? value.error.code : undefined));
    default:
        return fail("event type=" + token(value.type));
    }
}

/**
 * create({provider, clock, conversation, captionLimit, log}) returns
 * {port, captureSink, playbackSource}. provider is the Providers.select
 * "openai-live" row. conversation(e) answers {net, key, language} for a
 * speech-open effect: the session's net owner, null or {secrets, reference},
 * and the speech language. captionLimit is the wire's transcript bound. log
 * receives keyed diagnostic lines. One session at a time is live; closed ones
 * finalize in the background.
 */
function create({ provider, clock, conversation, captionLimit, log }) {
    Providers.assertRow(provider);
    if (provider.driver !== "openai-live") fail("driver");
    if (!Number.isSafeInteger(captionLimit) || captionLimit < 1) fail("caption-limit");
    const sessions = new Map();
    let live = null;

    function clear(session, name) {
        if (session.timers[name] !== null) clock.clear(session.timers[name]);
        session.timers[name] = null;
    }
    function release(session) {
        for (const name of Object.keys(session.timers)) clear(session, name);
        if (session.next !== null) session.next.stream.destroy();
        session.next = null;
        session.playing = null;
        session.capture = null;
        session.pending = [];
        if (session.channel !== null) session.channel.close();
        session.state = { kind: "ended" };
        sessions.delete(session.op);
        if (live === session) live = null;
    }
    function failed(session, reason) {
        switch (session.state.kind) {
        case "ended": return;
        case "closing": finalize(session, reason); return;
        case "connecting": case "starting": case "running":
            release(session);
            session.events.failed(reason);
            return;
        default: throw new Error("jarvis: live=state");
        }
    }
    function finalize(session, cause) {
        release(session);
        if (cause !== null) log("jarvis: live=close-unconfirmed cause=" + cause);
    }
    function send(session, value) {
        const answer = session.channel.send(Policy.item(JSON.stringify(value), ["speech"]));
        if (answer.kind !== "send") fail("release-" + answer.kind);
        if (session.channel.bufferedAmount > SEND_BACKLOG_BYTES) fail("send-backlog");
    }
    function append(session, pcm) {
        try { send(session, { type: "session.input_audio.append", audio: pcm.toString("base64") }); }
        catch (error) { failed(session, reasonOf(error)); return false; }
        session.sent += pcm.length / 2;
        return true;
    }
    // The session timeline advances with input audio. While no microphone
    // feeds it, silence lets the voice model hear the turn end and answer.
    function silence(session) {
        session.timers.silence = clock.set(() => {
            session.timers.silence = null;
            if (session.capture === null) {
                const now = clock.now();
                const samples = Math.min(Math.floor((now - session.inputAt) * PCM_RATE / 1000),
                    PCM_RATE * SILENCE_MAX_MS / 1000);
                session.inputAt = now;
                if (samples > 0 && !append(session, Buffer.alloc(samples * 2))) return;
            }
            silence(session);
        }, SILENCE_TICK_MS);
    }
    function activity(session) {
        if (session.state.kind !== "running") return;
        clear(session, "idle");
        session.timers.idle = clock.set(() => {
            session.timers.idle = null;
            // A queued or playing reply is activity; its close restarts this.
            if (session.playing !== null || session.next !== null) return;
            session.events.idle();
        }, IDLE_MS);
    }
    function gap(session) {
        clear(session, "gap");
        const reply = session.playing;
        session.timers.gap = clock.set(() => {
            session.timers.gap = null;
            if (session.playing !== reply || reply.kind !== "open") return;
            reply.kind = "ended";
            reply.stream.push(null);
        }, REPLY_GAP_MS);
    }
    function started(session) {
        if (session.state.kind !== "starting") fail("event-order");
        clear(session, "start");
        session.state = { kind: "running" };
        const pending = Buffer.concat(session.pending);
        session.pending = [];
        for (let offset = 0; offset < pending.length; offset += APPEND_BYTES)
            if (!append(session, pending.subarray(offset, offset + APPEND_BYTES))) return;
        session.inputAt = clock.now();
        silence(session);
        activity(session);
    }
    function output(session, pcm) {
        if (session.output.kind === "discarding" || pcm.length === 0) return;
        activity(session);
        let reply = session.playing !== null && session.playing.kind === "open" ? session.playing : session.next;
        if (reply === null) {
            reply = { kind: "open", stream: new Readable({ highWaterMark: REPLY_BYTES, read() {} }) };
            session.next = reply;
            session.events.speak();
        }
        // The provider cannot be paused: a full queue faults, never drops speech.
        if (!reply.stream.push(pcm)) { failed(session, "live=output-overflow"); return; }
        if (reply === session.playing) gap(session);
    }
    function caption(session, role, delta, start, end) {
        activity(session);
        if (role === "user" && session.output.kind === "discarding" && start >= session.output.from)
            session.output = { kind: "passing" };
        let text = delta.replace(/[\x00-\x1f\x7f]/g, " ");
        let segment = session.segments[role];
        const emit = (value, stage) => {
            session.rev++;
            session.events.transcript({ role, text: value, stage, rev: session.rev });
        };
        if (segment !== null && start - segment.end >= SEGMENT_GAP_MS) {
            emit(segment.text, "final");
            segment = session.segments[role] = null;
        }
        while (text !== "") {
            if (segment !== null && segment.text.length === captionLimit) {
                emit(segment.text, "final");
                segment = null;
            }
            if (segment === null) segment = session.segments[role] = { text: "", end };
            const room = captionLimit - segment.text.length;
            segment.text += text.slice(0, room);
            text = text.slice(room);
            segment.end = end;
            emit(segment.text, "partial");
        }
    }
    function receive(session, data) {
        if (session.state.kind === "ended") return;
        let event;
        try { event = eventOf(data); } catch (error) { failed(session, reasonOf(error)); return; }
        const kind = session.state.kind;
        try {
            switch (event.kind) {
            case "started": started(session); break;
            case "audio":
                if (kind === "running") output(session, event.pcm);
                else if (kind !== "closing") fail("event-order");
                break;
            case "caption":
                if (kind === "running") caption(session, event.role, event.text, event.start, event.end);
                else if (kind !== "closing") fail("event-order");
                break;
            case "closed":
                if (kind === "closing") finalize(session, null);
                else fail("closed reason=" + event.reason);
                break;
            case "ignored": break;
            default: throw new Error("jarvis: live=event-kind");
            }
        } catch (error) { failed(session, reasonOf(error)); }
    }
    function connect(session, { net, key, language }) {
        if (key === null) fail("no-key");
        Net.assertKeyTarget(provider.base, key.reference.origin);
        session.start = { type: "session.start", session: { model: MODEL,
            instructions: Guidance.compose("duplex", "duplex", language).instructions,
            audio: { format: FORMAT }, delegation: { type: "client" }, ...provider.noStore } };
        const secret = key.secrets.lookup(key.reference);
        let answer;
        try {
            answer = net.websocket(Policy.item(provider.base, ["speech"]), { url: provider.base,
                key: { origin: key.reference.origin, header: "authorization", prefix: "Bearer ", value: secret.toString("utf8") } });
        } finally { secret.fill(0); }
        if (answer.kind !== "channel") fail("release-" + answer.kind);
        session.channel = answer;
        answer.events.addEventListener("open", () => {
            if (session.state.kind !== "connecting") return;
            session.state = { kind: "starting" };
            try { send(session, session.start); } catch (error) { failed(session, reasonOf(error)); }
        });
        answer.events.addEventListener("message", event => receive(session, event.data));
        // WHATWG WebSocket fires close after every error; close owns the outcome.
        answer.events.addEventListener("close", event => {
            if (session.state.kind === "closing") finalize(session, "disconnected");
            else failed(session, "live=disconnected code=" + event.code);
        });
    }

    const port = {
        open(e, events) {
            if (live !== null) throw new Error("jarvis: live=session-live");
            const now = clock.now();
            const session = { op: e.op, events, state: { kind: "connecting" }, channel: null, start: null,
                timers: { start: null, silence: null, idle: null, gap: null, close: null },
                pending: [], pendingBytes: 0, inputAt: now, sent: 0, capture: null, playing: null, next: null,
                output: { kind: "passing" }, segments: { user: null, assistant: null }, rev: 0 };
            sessions.set(e.op, session);
            live = session;
            session.timers.start = clock.set(() => failed(session, "live=start-timeout"), START_WAIT_MS);
            try { connect(session, conversation(e)); } catch (error) { failed(session, reasonOf(error)); }
        },
        close(e) {
            const session = sessions.get(e.target);
            if (session === undefined) return;
            if (live === session) live = null;
            if (e.mode === "abort" || session.state.kind !== "running") {
                finalize(session, e.mode === "abort" ? "lease" : session.state.kind);
                return;
            }
            for (const name of ["silence", "idle", "gap"]) clear(session, name);
            if (session.next !== null) session.next.stream.destroy();
            session.next = null;
            session.capture = null;
            try { send(session, { type: "session.close" }); }
            catch (error) { finalize(session, reasonOf(error)); return; }
            session.state = { kind: "closing" };
            session.timers.close = clock.set(() => finalize(session, "timeout"), CLOSE_WAIT_MS);
            const closing = [...sessions.values()].filter(value => value.state.kind === "closing");
            if (closing.length > FINALIZING) finalize(closing[0], "finalizing-limit");
        },
        // The provider has no truncate event. Drop the queued reply, then the
        // rest of the interrupted one: output passes again once the user's
        // speech after this point on the session timeline is transcribed.
        flush(e) {
            const session = sessions.get(e.target);
            if (session === undefined || session !== live) return;
            session.output = { kind: "discarding", from: Math.floor(session.sent * 1000 / PCM_RATE) };
            clear(session, "gap");
            if (session.next !== null) session.next.stream.destroy();
            session.next = null;
            // Audio's flush releases the reply it holds.
            session.playing = null;
            activity(session);
        }
    };

    function captureSink() {
        const session = live;
        if (session === null) return null;
        const sink = new Writable({
            write(pcm, encoding, done) {
                done();
                if (session.capture !== sink) return;
                if (pcm.length % 2 !== 0) { failed(session, "live=input-frame"); return; }
                session.inputAt = clock.now();
                switch (session.state.kind) {
                case "connecting": case "starting":
                    // The opening words wait for session.started, within its bound.
                    session.pendingBytes += pcm.length;
                    if (session.pendingBytes > PENDING_BYTES) { failed(session, "live=input-overflow"); return; }
                    session.pending.push(Buffer.from(pcm));
                    return;
                case "running": append(session, pcm); return;
                // Frames in flight after the session ended; Session closes capture.
                case "closing": case "ended": return;
                default: throw new Error("jarvis: live=state");
                }
            }
        });
        session.capture = sink;
        sink.once("close", () => {
            if (session.capture !== sink) return;
            session.capture = null;
            session.inputAt = clock.now();
        });
        activity(session);
        return sink;
    }

    function playbackSource(source) {
        const session = live;
        if (session === null || session.op !== source || session.next === null) return null;
        const reply = session.next;
        session.next = null;
        session.playing = reply;
        reply.stream.once("close", () => {
            if (session.playing !== reply) return;
            session.playing = null;
            clear(session, "gap");
            activity(session);
        });
        if (reply.kind === "open") gap(session);
        return reply.stream;
    }

    return Object.freeze({ port: Object.freeze(port), captureSink, playbackSource });
}

module.exports = { create };
