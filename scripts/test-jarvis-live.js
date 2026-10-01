#!/usr/bin/env node
// The GPT-Live duplex engine against schema-pinned scripts that a loopback
// WebSocket server replays inside the J09 world, through the real Session
// reducer and runner. In-memory capture and playback ports follow Audio's
// sink and source contract. A manual clock drives silence, reply ends, idle
// close and finalization. Excerpt and scripts: scripts/fixtures/jarvis-live/.
// The key is the keys-world stand-in's fixture value; no network or account.
"use strict";
const { assert, fs, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const { standins } = require("./fixtures/jarvis/keys-world.js");
const Ws = require("./fixtures/jarvis/websocket.js");
const Check = require("./fixtures/schema-check.js");
const excerpt = require("./fixtures/jarvis-live/gpt-live.schema.json");
const fixtures = require("./fixtures/jarvis-live/gpt-live-scripts.json");
const { load } = require("../bin/lib/qml-library.js");
const http = require("node:http");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const file = path.join(backend, "GptLive.js");
const Protocol = load(path.join(tree, "shell/plugins/vgs.jarvis/JarvisProtocol.js"));
const KEY = "test-key-must-stay-private";
const PRIVATE = "fixture-private-provider-text";
const CLIENT = { "session.start": "LiveSessionStartEvent", "session.input_audio.append": "LiveInputAudioAppendEvent",
    "session.close": "LiveSessionCloseParam" };
const SERVER = { "session.started": "LiveSessionStarted", "session.output_audio.delta": "LiveOutputAudioDelta",
    "session.input_transcript.delta": "LiveInputTranscriptDelta", "session.output_transcript.delta": "LiveOutputTranscriptDelta",
    "session.usage.updated": "LiveSessionUsageUpdated", info: "LiveInfoEvent", "session.closed": "LiveSessionClosed",
    error: "LiveErrorEvent", "session.delegation.created": "LiveDelegationCreated" };
function pinned(name, value, label) {
    assert.equal(typeof name, "string", label + " names a pinned event: " + value.type);
    assert.deepEqual(Check.errors(excerpt, name, value), [], label + " matches the pinned " + name);
}
for (const [name, events] of Object.entries(fixtures.scripts)) for (const event of events) pinned(SERVER[event.type], event, name);
const turn = () => new Promise(resolve => setImmediate(resolve));
async function until(check, label) {
    // Loopback delivery and stream events, not a latency measurement. Each
    // control's red result waits for this bound, so it stays short.
    const deadline = Date.now() + 2000;
    while (!check()) {
        assert.ok(Date.now() < deadline, label);
        await new Promise(resolve => setTimeout(resolve, 2));
    }
}
function manual() {
    let now = 0, next = 1;
    const timers = new Map();
    return { now: () => now, set(fn, ms) { timers.set(next, { at: now + Math.max(0, ms), fn }); return next++; },
        clear(id) { timers.delete(id); },
        advance(ms) {
            const end = now + ms;
            for (;;) {
                let due = null;
                for (const [id, timer] of timers) if (timer.at <= end && (due === null || timer.at < due[1].at)) due = [id, timer];
                if (due === null) break;
                timers.delete(due[0]);
                now = due[1].at;
                due[1].fn();
            }
            now = end;
        } };
}
// Paced silence leaves once a tick. Yielding between simulated seconds lets
// the socket drain as real time would; one burst would read as a backlog.
async function elapse(w, ms) {
    for (let left = ms; left > 0; left -= 1000) {
        w.clock.advance(Math.min(1000, left));
        await new Promise(resolve => setTimeout(resolve, 0));
    }
}
const bytes = (w, value) => w.played.reduce((sum, { chunk }) => sum + chunk.filter(byte => byte === value).length, 0);

world(async () => {
    const childEnv = {};
    for (const name of ["PATH", "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR"])
        childEnv[name] = process.env[name];
    const lookups = () => {
        const calls = path.join(process.env.XDG_STATE_HOME, "secret-calls");
        return fs.existsSync(calls) ? fs.readFileSync(calls, "utf8").trim().split("\n")
            .filter(line => JSON.parse(line).argv[0] === "lookup").length : 0;
    };
    function listen() {
        const conns = [];
        let taken = 0;
        const instance = http.createServer((request, response) => { response.writeHead(404); response.end(); });
        instance.on("upgrade", (request, socket) => {
            const conn = { url: request.url, headers: request.headers, events: [], cursor: 0, socket, ended: false,
                play(name) { for (const event of fixtures.scripts[name]) this.raw(JSON.stringify(event)); },
                send(event) { pinned(SERVER[event.type], event, "raw"); this.raw(JSON.stringify(event)); },
                raw(data, opcode = 1) { socket.write(Ws.frame(opcode, data)); },
                count: type => conn.events.filter(event => event.type === type).length,
                async event(type) {
                    await until(() => conn.events.slice(conn.cursor).some(event => event.type === type), "client sends " + type);
                    const index = conn.events.findIndex((event, at) => at >= conn.cursor && event.type === type);
                    conn.cursor = index + 1;
                    return conn.events[index];
                } };
            conns.push(conn);
            Ws.accept(request, socket);
            socket.on("data", Ws.decoder(({ opcode, payload }) => {
                if (opcode === 8) { socket.end(Ws.frame(8, payload)); return; }
                assert.equal(opcode, 1, "client events are text frames");
                const value = JSON.parse(payload.toString());
                pinned(CLIENT[value.type], value, "client");
                conn.events.push(value);
            }));
            socket.on("close", () => { conn.ended = true; });
            // A fixture socket reset after the engine closes is not evidence.
            socket.on("error", () => {});
        });
        return new Promise((resolve, reject) => {
            instance.once("error", reject);
            instance.listen(0, "127.0.0.1", () => resolve({ instance, conns,
                origin: "http://127.0.0.1:" + instance.address().port,
                async accept() {
                    await until(() => conns.length > taken, "the engine connects");
                    return conns[taken++];
                } }));
        });
    }
    const main = await listen();
    const other = await listen();
    const nets = [];
    let conversations = 0;

    // A disposable backend whose provider row points at the loopback server.
    function kitFrom(folder, edits = []) {
        const table = fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "live-kit-"));
        for (const sibling of fs.readdirSync(folder).filter(name => name.endsWith(".js")))
            fs.copyFileSync(path.join(folder, sibling), path.join(table, sibling));
        fs.cpSync(path.join(backend, "skills"), path.join(table, "skills"), { recursive: true });
        for (const [name, needle, replacement] of [["Providers.js", '"wss://api.openai.com/v1/live/sessions"',
            JSON.stringify(main.origin.replace("http:", "ws:") + "/v1/live/sessions")], ...edits]) {
            const source = fs.readFileSync(path.join(table, name), "utf8");
            assert.equal(source.split(needle).length - 1, 1, name + " kit substitution");
            fs.writeFileSync(path.join(table, name), source.replace(needle, replacement));
        }
        const load = name => require(path.join(table, name));
        return { Live: load("GptLive.js"), Policy: load("Policy.js"), Net: load("net.js"), Providers: load("Providers.js"),
            Secrets: load("Secrets.js"), Runner: load("session-runner.js") };
    }

    function rig(kit, { key = "own", mode = "hold" } = {}) {
        const clock = manual();
        const w = { clock, played: [], flushes: 0, transcripts: [], logs: [], collected: [], sink: null, source: null, handed: [] };
        const store = new kit.Secrets.Secrets(path.join(childEnv.XDG_STATE_HOME, "vgs/jarvis"), childEnv);
        const reference = kit.Secrets.ownReference("openai", "fixture", key === "elsewhere" ? other.origin : main.origin);
        const secrets = { lookup: value => { const secret = store.lookup(value); w.handed.push(secret); return secret; } };
        const recipients = kit.Policy.recipients({ conversation: "live-" + ++conversations, profile: "standard", cloudVision: "ask",
            brain: { kind: "local", provider: "fixture-brain", account: "" },
            speech: [{ kind: "network", provider: "openai-live", account: "fixture", origin: main.origin }] });
        w.net = kit.Net.create(recipients);
        nets.push(w.net);
        const engine = kit.Live.create({ provider: kit.Providers.select("openai-live"), clock,
            captionLimit: Protocol.TRANSCRIPT_CHARS, log: line => w.logs.push(line),
            conversation: () => ({ net: w.net, key: key === null ? null : { secrets, reference }, language: "" }) });
        const ports = kit.Runner.unavailable();
        ports.capture = {
            // Audio refuses capture without a sink, as here.
            open: (e, done, failed) => {
                w.sink = engine.captureSink(e);
                if (w.sink === null) failed("audio-start: speech-unavailable"); else done();
            },
            close: (e, done) => { if (w.sink !== null) w.sink.destroy(); w.sink = null; done(); },
            collect: e => w.collected.push(e)
        };
        ports.playback = {
            start: (e, done, failed) => {
                const source = engine.playbackSource(e.source);
                if (source === null) { failed("playback-source-unavailable"); return; }
                w.source = source;
                source.on("data", chunk => w.played.push({ chunk, flush: w.flushes }));
                source.on("end", () => { if (w.source === source) { w.source = null; done(); } });
            },
            flush: (e, done) => { w.flushes++; if (w.source !== null) w.source.destroy(); w.source = null; done(); }
        };
        // The daemon's wire mapping, judged by the shared protocol.
        ports.transcript = e => {
            Protocol.accept(JSON.stringify({ v: 1, type: "transcript", gen: e.gen, revision: "a".repeat(64),
                role: e.role, text: e.text, stage: e.stage, rev: e.rev }), "daemon");
            w.transcripts.push({ role: e.role, text: e.text, stage: e.stage, rev: e.rev });
        };
        ports.mute = { store: () => {} };
        ports.speech = engine.port;
        w.runner = new kit.Runner.SessionRunner(Protocol.Session, ports, clock, (state, phase) => { w.state = state; w.phase = phase; });
        w.dispatch = (type, values = {}) => w.runner.dispatch({ type, ...values });
        w.dispatch("snapshot", { locked: false, engine: "duplex", configured: true, settings: { mode } });
        w.dispatch("indicator", { shown: true });
        return w;
    }
    // Talk opens the session; release leaves it running on paced silence.
    async function running(kit, options) {
        const w = rig(kit, options);
        w.dispatch("talk-down");
        const conn = await main.accept();
        await conn.event("session.start");
        conn.play("started");
        w.sink.write(Buffer.alloc(960, 5));
        await conn.event("session.input_audio.append");
        w.dispatch("talk-up");
        await turn();
        w.clock.advance(100);
        await conn.event("session.input_audio.append");
        return { w, conn };
    }
    // Session state comes from the QML library realm; compare its JSON.
    const fault = (w, reason) => assert.deepEqual(JSON.parse(JSON.stringify(w.state.fault)), { kind: "error", reason, retry: 0 });
    function quiet(w, conn) {
        const all = JSON.stringify([w.state, w.logs, w.transcripts, conn === undefined ? [] : conn.events]);
        assert.equal(all.includes(KEY), false, "no key in state, log, transcript or frame");
        assert.equal(all.includes(PRIVATE), false, "no provider message text");
    }

    async function roundTrip(kit) {
        const w = rig(kit);
        const looked = lookups();
        w.dispatch("talk-down");
        assert.equal(lookups(), looked + 1, "the key is looked up when the session first needs it");
        assert.ok(w.handed.length === 1 && w.handed[0].every(byte => byte === 0), "the looked-up key is zeroed after the handshake");
        const conn = await main.accept();
        assert.equal(conn.url, "/v1/live/sessions");
        assert.equal(conn.headers.authorization, "Bearer " + KEY);
        const start = await conn.event("session.start");
        assert.equal(start.session.model, "gpt-live-1");
        assert.deepEqual(start.session.audio, { format: { type: "audio/pcm", rate: 24000 } });
        assert.deepEqual(start.session.delegation, { type: "client" });
        assert.equal(start.session.store, false);
        assert.match(start.session.instructions, /You are Jarvis/);
        w.sink.write(Buffer.alloc(4800, 5));
        await turn();
        assert.equal(conn.count("session.input_audio.append"), 0, "no audio before session.started");
        conn.play("started");
        assert.deepEqual(Buffer.from((await conn.event("session.input_audio.append")).audio, "base64"), Buffer.alloc(4800, 5),
            "opening words wait for session.started, then leave once");
        w.sink.write(Buffer.alloc(960, 6));
        assert.deepEqual(Buffer.from((await conn.event("session.input_audio.append")).audio, "base64"), Buffer.alloc(960, 6));
        w.dispatch("talk-up");
        await turn();
        w.clock.advance(100);
        assert.deepEqual(Buffer.from((await conn.event("session.input_audio.append")).audio, "base64"), Buffer.alloc(4800),
            "released talk leaves the session on paced silence");
        conn.play("reply-old");
        await until(() => bytes(w, 0x11) === 1440, "the reply reaches playback");
        assert.equal(w.phase, "speaking");
        w.clock.advance(499);
        await turn();
        assert.equal(w.state.playback.kind, "playing", "a reply continues within its gap");
        w.clock.advance(1);
        await until(() => w.state.playback.kind === "idle", "the reply ends after its gap");
        assert.equal(w.phase, "idle");
        assert.deepEqual(w.collected, [], "the duplex engine collects no utterance");
        assert.equal(w.state.fault.kind, "none");
        quiet(w, conn);
        return { w, conn };
    }

    async function idle(kit) {
        const { w, conn } = await roundTrip(kit);
        await elapse(w, 59999);
        assert.equal(conn.count("session.close"), 0, "no close before 60 s idle");
        assert.equal(w.state.speech.kind, "open");
        w.clock.advance(1);
        await conn.event("session.close");
        assert.equal(w.state.speech.kind, "closed");
        assert.equal(w.state.conversation.kind, "ended", "idle close ends the conversation");
        assert.equal(w.state.fault.kind, "none");
        conn.play("closed");
        await until(() => conn.ended, "the engine releases the socket after session.closed");
        assert.deepEqual(w.logs, []);
    }

    async function unconfirmed(kit) {
        const { w, conn } = await running(kit);
        w.dispatch("stop");
        await conn.event("session.close");
        await elapse(w, 14999);
        assert.equal(conn.ended, false, "the engine waits for session.closed");
        w.clock.advance(1);
        await until(() => conn.ended, "the bounded wait releases the socket");
        assert.deepEqual(w.logs, ["jarvis: live=close-unconfirmed cause=timeout"]);
        const lease = await running(kit);
        lease.w.runner.close();
        await until(() => lease.conn.ended, "lease loss aborts at once");
        assert.equal(lease.conn.count("session.close"), 0);
        assert.deepEqual(lease.w.logs, ["jarvis: live=close-unconfirmed cause=lease"]);
    }

    async function finalizing(kit) {
        const w = rig(kit, { mode: "toggle" });
        const conns = [];
        for (let index = 0; index < 5; index++) {
            w.clock.advance(300);
            w.dispatch("talk-down");
            const conn = await main.accept();
            await conn.event("session.start");
            conn.play("started");
            w.sink.write(Buffer.alloc(960));
            await conn.event("session.input_audio.append");
            w.clock.advance(300);
            w.dispatch("talk-down");
            await conn.event("session.close");
            conns.push(conn);
        }
        await until(() => conns[0].ended, "past four finalizing sessions the oldest is released");
        assert.deepEqual(conns.map(conn => conn.ended), [true, false, false, false, false]);
        assert.deepEqual(w.logs, ["jarvis: live=close-unconfirmed cause=finalizing-limit"]);
    }

    async function captions(kit) {
        const { w, conn } = await running(kit);
        conn.play("captions");
        conn.send({ type: "session.output_transcript.delta", event_id: "evt_long", delta: "x\u0007".repeat(2500), start_ms: 5000, end_ms: 9000 });
        await until(() => w.transcripts.length === 9, "captions reach the wire");
        const long = "x ".repeat(2500);
        assert.deepEqual(w.transcripts, [
            { role: "user", text: "What is", stage: "partial", rev: 1 },
            { role: "user", text: "What is the time?", stage: "partial", rev: 2 },
            { role: "assistant", text: "It is noon.", stage: "partial", rev: 3 },
            { role: "user", text: "What is the time?", stage: "final", rev: 4 },
            { role: "user", text: "Thanks.", stage: "partial", rev: 5 },
            { role: "assistant", text: "It is noon.", stage: "final", rev: 6 },
            { role: "assistant", text: long.slice(0, 4096), stage: "partial", rev: 7 },
            { role: "assistant", text: long.slice(0, 4096), stage: "final", rev: 8 },
            { role: "assistant", text: long.slice(4096), stage: "partial", rev: 9 }
        ]);
        conn.play("usage");
        conn.play("speech-before");
        await until(() => w.transcripts.length === 10, "usage and info pass without a fault");
        assert.equal(w.state.fault.kind, "none");
        quiet(w, conn);
    }

    // An interrupted reply already playing: its later audio never plays.
    async function interruptPlaying(kit) {
        const { w, conn } = await running(kit);
        conn.play("reply-old");
        await until(() => bytes(w, 0x11) === 1440, "the old reply plays");
        w.dispatch("talk-down");
        assert.equal(w.flushes, 1);
        assert.equal(w.state.playback.kind, "idle");
        conn.play("late-old");
        conn.play("speech-before");
        conn.play("late-old");
        conn.play("speech-after");
        await until(() => w.transcripts.some(item => item.text.startsWith("Stop")), "the new utterance arrives");
        assert.equal(w.played.filter(item => item.flush === 1).length, 0, "no audio of the interrupted reply after the flush");
        assert.equal(w.state.speech.reply.kind, "none");
        conn.play("reply-new");
        w.dispatch("talk-up");
        await until(() => bytes(w, 0x22) === 1440, "the reply to the new utterance plays");
        assert.equal(w.played.filter(item => item.flush === 1).reduce((sum, item) => sum + item.chunk.filter(b => b === 0x11).length, 0), 0);
    }

    // A reply still queued behind a held talk key is dropped whole.
    async function interruptQueued(kit) {
        const { w, conn } = await running(kit);
        w.dispatch("talk-down");
        conn.play("speech-after");
        conn.play("reply-old");
        await until(() => w.state.speech.reply.kind === "waiting", "the reply waits behind the held key");
        assert.equal(w.state.capture.kind, "open", "a reply never cuts off held talk without echo cancellation");
        w.dispatch("interrupt");
        assert.equal(w.state.speech.reply.kind, "none");
        w.dispatch("talk-up");
        await turn();
        assert.equal(w.state.playback.kind, "idle", "the interruption cleared the queue");
        conn.play("speech-after");
        conn.play("reply-new");
        await until(() => bytes(w, 0x22) === 1440, "the next reply plays");
        assert.equal(bytes(w, 0x11), 0, "no queued audio of the interrupted reply plays");
    }

    async function failures(kit) {
        const rows = [
            ["error", conn => conn.play("error"), "live=server-error code=unknown_parameter"],
            ["delegation", conn => conn.play("delegation"), "live=delegation-unsupported"],
            ["expired", conn => conn.play("expired"), "live=closed reason=expired"],
            ["json", conn => conn.raw("{"), "live=frame-json"],
            ["binary", conn => conn.raw(Buffer.from([1, 2]), 2), "live=frame-binary"],
            ["odd-audio", conn => conn.send({ type: "session.output_audio.delta", delta: "AAAA" }), "live=output-audio"],
            ["not-base64", conn => conn.send({ type: "session.output_audio.delta", delta: "AA=A" }), "live=output-audio"],
            ["unrequested", conn => conn.raw(JSON.stringify({ type: "response.event", event_id: "e", event: {} })), "live=event type=response.event"],
            ["reset", conn => conn.socket.destroy(), "live=disconnected code=1006"]
        ];
        for (const [name, act, reason] of rows) {
            const { w, conn } = await running(kit);
            act(conn);
            await until(() => w.state.fault.kind === "error", name + " faults");
            fault(w, reason);
            assert.equal(w.state.speech.kind, "closed", name + " releases the session");
            assert.equal(w.state.conversation.kind, "ended", name + " ends the conversation: no silent provider switch");
            await until(() => conn.ended, name + " closes the socket");
            quiet(w, conn);
        }
        const w = rig(kit);
        w.dispatch("talk-down");
        const conn = await main.accept();
        await conn.event("session.start");
        await elapse(w, 19999);
        assert.equal(w.state.fault.kind, "none");
        w.clock.advance(1);
        fault(w, "live=start-timeout");
        await until(() => conn.ended, "start timeout closes the socket");
    }

    async function keys(kit) {
        const connections = main.conns.length + other.conns.length;
        const looked = lookups();
        const elsewhere = rig(kit, { key: "elsewhere" });
        elsewhere.dispatch("talk-down");
        fault(elsewhere, "net=key-origin");
        assert.equal(lookups(), looked, "a key bound to another origin is refused before any lookup");
        const missing = rig(kit, { key: null });
        missing.dispatch("talk-down");
        fault(missing, "live=no-key");
        await turn();
        assert.equal(main.conns.length + other.conns.length, connections, "no connection without a usable key");
    }

    async function release(kit) {
        const w = rig(kit);
        w.dispatch("talk-down");
        const conn = await main.accept();
        await conn.event("session.start");
        conn.play("started");
        w.sink.write(Buffer.alloc(960, 5));
        await until(() => w.state.fault.kind === "error", "a withheld frame faults");
        fault(w, "live=release-withhold");
        await until(() => conn.ended, "the withheld session closes");
        assert.equal(conn.count("session.input_audio.append"), 0, "a withheld frame writes nothing");
    }

    async function bounds(kit) {
        const early = rig(kit);
        early.dispatch("talk-down");
        await main.accept();
        for (let sent = 0; sent < 960000; sent += 48000) early.sink.write(Buffer.alloc(48000));
        assert.equal(early.state.fault.kind, "none", "20 s of opening words fit");
        early.sink.write(Buffer.alloc(2));
        fault(early, "live=input-overflow");
        const held = await running(kit);
        held.w.dispatch("talk-down");
        held.conn.play("speech-after");
        const chunk = { type: "session.output_audio.delta", delta: Buffer.alloc(65536).toString("base64") };
        for (let index = 0; index < 19; index++) held.conn.send(chunk);
        held.conn.send({ type: "session.output_transcript.delta", event_id: "mark", delta: "mark", start_ms: 1, end_ms: 2 });
        await until(() => held.w.transcripts.length === 2, "19 queued chunks arrive");
        assert.equal(held.w.state.fault.kind, "none", "a queue under the playback allowance is kept");
        for (let index = 0; index < 2; index++) held.conn.send(chunk);
        await until(() => held.w.state.fault.kind === "error", "past the allowance the reply faults");
        fault(held.w, "live=output-overflow");
        const stalled = await running(kit);
        stalled.conn.socket.pause();
        for (let index = 0; index < 600 && stalled.w.state.fault.kind === "none"; index++) {
            stalled.w.clock.advance(1000);
            await new Promise(resolve => setTimeout(resolve, 1));
        }
        fault(stalled.w, "live=send-backlog");
        stalled.conn.socket.resume();
    }

    const cases = { roundTrip, idle, unconfirmed, finalizing, captions, interruptPlaying, interruptQueued,
        failures, keys, bounds };
    const withheld = ["Policy.js", "const current = item(value.content, value.labels);",
        'const current = item(value.content, value.labels);\n    if (String(current.content).includes("input_audio.append")) return { kind: "withhold", content: "[withheld]", labels: current.labels };'];
    let controls = 0;
    async function control(name, needle, replacement, check) {
        await mutant(file, name, needle, replacement, async (_module, folder) => check(folder), "GptLive.js");
        controls++;
        console.log("control=" + name + " detected");
    }
    try {
        for (const check of Object.values(cases)) await check(kitFrom(backend));
        await release(kitFrom(backend, [withheld]));
        const as = name => folder => cases[name](kitFrom(folder));
        const mutations = [
            ["flush-queue", "if (session.next !== null) session.next.stream.destroy();\n            session.next = null;\n            // Audio's",
                "// Audio's", as("interruptQueued")],
            ["discard", 'if (session.output.kind === "discarding" || pcm.length === 0) return;', "if (pcm.length === 0) return;", as("interruptPlaying")],
            ["discard-timeline", "&& start >= session.output.from", "", as("interruptPlaying")],
            ["idle-rule", "}, IDLE_MS);", "}, IDLE_MS + 1);", as("idle")],
            ["close-wait", 'clock.set(() => finalize(session, "timeout"), CLOSE_WAIT_MS)', "null", as("unconfirmed")],
            ["finalizing", 'if (closing.length > FINALIZING) finalize(closing[0], "finalizing-limit");', "", as("finalizing")],
            ["server-error", 'return fail("server-error code="', 'return { kind: "ignored" }; return fail("server-error code="', as("failures")],
            ["delegation", 'return fail("delegation-unsupported");', 'return { kind: "ignored" };', as("failures")],
            ["disconnected", 'else failed(session, "live=disconnected code=" + event.code);', "", as("failures")],
            ["start-timeout", 'clock.set(() => failed(session, "live=start-timeout"), START_WAIT_MS)', "null", as("failures")],
            ["key-first", "Net.assertKeyTarget(provider.base, key.reference.origin);", "", as("keys")],
            ["key-zero", "} finally { secret.fill(0); }", "} finally { void secret; }", as("roundTrip")],
            ["pending", 'case "connecting": case "starting":\n                    // The opening', 'case "connecting": case "starting": return;\n                    // The opening', as("roundTrip")],
            ["silence", "if (samples > 0 && !append(session, Buffer.alloc(samples * 2))) return;", "", as("roundTrip")],
            ["reply-gap", "reply.stream.push(null);", "", as("roundTrip")],
            ["segment-gap", "start - segment.end >= SEGMENT_GAP_MS", "false", as("captions")],
            ["segment-limit", "if (segment !== null && segment.text.length === captionLimit) {", "if (false) {", as("captions")],
            ["input-overflow", 'if (session.pendingBytes > PENDING_BYTES) { failed(session, "live=input-overflow"); return; }', "", as("bounds")],
            ["output-overflow", 'if (!reply.stream.push(pcm)) { failed(session, "live=output-overflow"); return; }', "reply.stream.push(pcm);", as("bounds")],
            ["backlog", 'if (session.channel.bufferedAmount > SEND_BACKLOG_BYTES) fail("send-backlog");', "", as("bounds")],
            ["release", 'if (answer.kind !== "send") fail("release-" + answer.kind);\n        if (session.channel', "if (session.channel",
                folder => release(kitFrom(folder, [withheld]))]
        ];
        for (const [name, needle, replacement, check] of mutations) await control(name, needle, replacement, check);
        console.log("test-jarvis-live: ok cases=" + (Object.keys(cases).length + 1) + " controls=" + controls
            + " connections=" + main.conns.length);
    } finally {
        for (const net of nets) net.close();
        for (const server of [main, other]) {
            for (const conn of server.conns) conn.socket.destroy();
            server.instance.closeAllConnections();
            await new Promise(resolve => server.instance.close(resolve));
        }
    }
}, standins)?.catch(error => { console.error(error); process.exitCode = 1; });
