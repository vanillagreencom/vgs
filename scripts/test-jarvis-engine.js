#!/usr/bin/env node
// The chained engine through the real Session, runner, Audio, router, audit,
// release gate and wire brain, with scripted speech adapters and a loopback
// brain inside the J09 world. Every request body is read at the server.
"use strict";
const { assert, fs, path, tree, world, until: wait } = require("./fixtures/jarvis/audio.js");
const { clock, turn } = require("./fixtures/jarvis/playback.js");
const Fixture = require("./fixtures/jarvis/engine.js");
const { load } = require("../bin/lib/qml-library.js");
const { utterance, text, calls, control } = Fixture;
// The ollama row's default port: free inside the private network namespace.
const PORT = 11434;
// Bounds a missing observation, not a latency: each rig runs real capture and
// player children, which a loaded host can delay.
const OBSERVE_MS = 15000;
const until = (check, message) => wait(check, message, OBSERVE_MS);
const INTERRUPTED = "[interrupted] The user heard none of your last reply.";
const heardOnly = prefix => "[interrupted] The user heard only this part of your last reply: \"" + prefix + "\"";
// A reply that opens its stream, then waits for the case's gate.
const pause = held => [{ delta: { role: "assistant", content: "" }, finish_reason: null }, { wait: held.wait }];
function gate() {
    let open;
    const wait = new Promise(resolve => { open = resolve; });
    return { wait, open };
}

function rig(kit, server, options = {}) {
    const backend = name => require(path.join(kit.folder, "backend", name));
    const Session = load(path.join(kit.folder, "Session.js"));
    const Protocol = load(path.join(kit.folder, "JarvisProtocol.js"));
    const { SessionRunner, unavailable } = backend("session-runner.js");
    const { Audio } = backend("Audio.js");
    const Audit = backend("Audit.js");
    const Router = backend("ToolRouter.js");
    const audioClock = clock();
    // Session deadlines run on an injected clock that only the case advances.
    let at = 0;
    const timers = new Map();
    const runnerClock = { now: () => at, set: (fn, ms) => { const key = {}; timers.set(key, { fn, at: at + ms }); return key; },
        clear: key => timers.delete(key) };
    const advanceRunner = ms => {
        at += ms;
        for (const [key, timer] of [...timers]) if (timer.at <= at) { timers.delete(key); timer.fn(); }
    };
    const state = fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "state-"));
    const audit = Audit.create({ state, now: () => Date.UTC(2026, 9, 1) });
    const faults = [], executions = [], held = [], partials = [], captions = [];
    const audio = new Audio({ session: Session, environment: { PATH: process.env.PATH, HOME: process.env.HOME,
        XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR }, clock: audioClock, offers: () => {}, level: () => {},
    fault: reason => faults.push(reason), captureSink: null, playbackSource: null });
    const ports = { ...unavailable(), mute: { store() {} } };
    ports.capture = { ...ports.capture, ...audio.capturePort };
    ports.transcript = e => captions.push([e.gen, e.role, e.stage, e.rev, e.text]);
    let engine = null;
    const runner = new SessionRunner(Session, ports, runnerClock, s => {
        audio.observe(s);
        if (engine !== null) engine.observe(s);
        if (s.gate.kind === "down") void audio.teardown("gate", ["capture", "playback"]);
        if (s.turn.kind === "collecting" && s.turn.partial !== "" && partials.at(-1) !== s.turn.partial)
            partials.push(s.turn.partial);
    });
    const router = Router.create({ session: Session, state: () => runner.state, dispatch: e => runner.dispatch(e), audit,
        context: () => ({ profile: "standard", locked: false, denied: null }),
        result: value => runner.ports.brain.outcome(value) });
    Object.assign(ports, router.ports);
    // The callback stands in for a command-ready executor; it never starts hyprctl.
    router.register("compositor", { commands: ["hyprctl"], timeoutMs: 30000, cancellable: false, start(call, done) {
        executions.push(call);
        if (options.holdTools) held.push(done);
        else done({ outcome: "completed", content: "focused " + call.args.window });
    } });
    router.register("clipboard", { commands: ["wl-paste"], timeoutMs: 30000, cancellable: false, start(call, done) {
        executions.push(call);
        done({ outcome: "completed", content: "clipboard words" });
    } });
    router.register("vision", { commands: ["grim"], timeoutMs: 30000, cancellable: false, start(call, done) {
        executions.push(call);
        done({ outcome: "completed", content: "screen text" });
    } });
    // Accounts.resolve has its own suite; this stand-in names a loopback row.
    const accounts = () => ({ secrets: null, resolve: id => ({ id, provider: "ollama", label: "local",
        source: { kind: "local", origin: "http://127.0.0.1:" + PORT }, model: "fixture-model" }) });
    engine = kit.Engine.create({ session: Session, state: () => runner.state, audit, router, accounts,
        policy: () => ({ profile: "standard", cloudVision: "ask" }), fault: reason => faults.push(reason),
        captionLimit: options.captionLimit ?? Protocol.TRANSCRIPT_CHARS });
    ports.brain = engine.brain;
    ports.capture.collect = engine.collect;
    ports.playback = engine.playback(audio.playbackPort);
    audio.captureSink = engine.captureSink;
    audio.playbackSource = engine.playbackSource;
    const configure = settings => {
        const answer = engine.configure(settings);
        runner.dispatch({ type: "snapshot", locked: false, engine: "chained",
            configured: answer.kind === "ready", settings });
        return answer;
    };
    assert.deepEqual(configure({ mode: options.mode ?? "hold", microphone: "", speaker: "", brain: "fixture-account" }), { kind: "ready" });
    runner.dispatch({ type: "indicator", shown: true });
    const rows = () => {
        const file = path.join(state, "audit/2026-10-01.jsonl");
        return fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim().split("\n").map(line => JSON.parse(line)) : [];
    };
    return { runner, audio, audioClock, engine, faults, executions, held, partials, captions, rows, configure, state, server, advanceRunner,
        s: () => runner.state,
        async close() {
            runner.close();
            engine.close();
            audit.close();
            await audio.close("test-end");
        } };
}

// One utterance through real capture: down, partials, up, final.
async function say(w, script, { waitPartial = true } = {}) {
    control.utterances.push(script);
    const before = w.server.requests.length;
    w.runner.dispatch({ type: "talk-down" });
    // An early final leaves collection; the case's own assertions judge it.
    const collecting = () => w.s().turn.kind === "collecting";
    await until(() => w.s().capture.kind === "open" || (w.s().turn.kind !== "none" && !collecting()),
        "capture opens from real fixture PCM");
    if (waitPartial && script.partials.length)
        await until(() => w.partials.at(-1) === script.partials.at(-1) || !collecting(), "partials reach Session");
    w.runner.dispatch({ type: "talk-up" });
    return before;
}
async function requested(w, count, label) {
    await until(() => w.server.requests.length >= count && w.server.requests[count - 1].body !== null, label);
    return w.server.requests[count - 1].body;
}
async function feeding(w, frames) {
    await until(() => w.audio.playback !== null && w.audio.playback.kind === "feeding"
        && w.audio.playback.received >= frames, "playback receives synthesized PCM");
}
// Advance the injected playback clock one node period at a time.
async function advance(w, periods) {
    for (let i = 0; i < periods; i++) {
        w.audioClock.advance(20);
        await turn();
    }
}
async function playOut(w) {
    for (let i = 0; i < 3000 && w.s().playback.kind !== "idle"; i++) {
        w.audioClock.advance(20);
        // Child pipes and the stand-in player's exit cross real I/O.
        await new Promise(resolve => setTimeout(resolve, 1));
    }
    assert.equal(w.s().playback.kind, "idle", "playback completes");
}
const user = body => body.messages.filter(message => message.role === "user").map(message => message.content);

async function cases(kit, server, only = null) {
    const run = async (name, check, options) => {
        if (only !== null && only !== name) return;
        Fixture.reset(options?.fixture);
        server.replies.length = 0;
        const w = rig(kit, server, options);
        try { await check(w); } finally {
            await w.close();
            server.closeAll();
        }
    };

    // Partials draw; the final alone reaches the brain. Brain text reaches
    // speech only through Speakable, and a played reply adds no context.
    await run("turn-loop", async w => {
        const first = await say(w, utterance("What time is it?", ["what", "what time"]));
        const body = await requested(w, first + 1, "the final transcript reaches the brain");
        assert.deepEqual(w.partials, ["what", "what time"], "partials reach Session in revision order");
        assert.deepEqual(user(body), ["What time is it?"]);
        assert.equal(body.messages[0].role, "system");
        assert.ok(Array.isArray(body.tools), "router offers reach the brain as a tool list");
        assert.ok(body.tools.some(tool => tool.function.name === "windows_focus"), "router offers reach the brain");
        server.replies.push(text("It is **noon**. ", "Anything else?"));
        await until(() => w.s().playback.kind === "playing", "speech starts playback");
        await playOut(w);
        assert.deepEqual(control.spoken, ["It is noon.", "Anything else?"], "only Speakable sentences reach speech");
        assert.equal(w.audio.lastPlayback.writtenFrames, (3 + 2) * Fixture.WORD_FRAMES, "every sentence's PCM played");
        const second = await say(w, utterance("Thanks."));
        server.replies.push(text(""));
        const next = await requested(w, second + 1, "the second turn");
        assert.deepEqual(next.messages.slice(1).map(message => [message.role, message.content]), [
            ["user", "What time is it?"], ["assistant", "It is **noon**. Anything else?"], ["user", "Thanks."]],
        "a fully played reply adds no heard context");
        await until(() => w.s().turn.kind === "none", "the empty reply completes");
        const gen = w.s().gen;
        assert.deepEqual(w.captions, [[gen, "assistant", "partial", 1, "It is noon."],
            [gen, "assistant", "partial", 2, "It is noon. Anything else?"], [gen, "assistant", "final", 3, "It is noon. Anything else?"]],
        "each released sentence grows the reply's caption, final at its end; an empty reply adds none");
        const releases = w.rows().filter(row => row.kind === "release");
        assert.ok(releases.length >= 5 && releases.every(row => row.decision === "send" && row.outcome === "pending"
            && row.effect === "external"), "each utterance, request and sentence is audited before transfer");
        assert.deepEqual([...control.labels], ["speech"], "frames and sentences reach the adapter as labelled items");
    });

    // Barge-in during speech, after the reply completed: the next request
    // carries exactly the heard prefix, read at the loopback server.
    await run("barge-in", async w => {
        const first = await say(w, utterance("What time is it?"));
        await requested(w, first + 1, "first request");
        server.replies.push(text("Hello there. ", "The time is noon."));
        await until(() => w.s().turn.kind === "none", "the reply completes before the interruption");
        await feeding(w, 2 * Fixture.WORD_FRAMES);
        await advance(w, 6);
        assert.equal(w.audio.playback.written, 1440 + 6 * 480, "the paced writer reached the planned count");
        control.utterances.push(utterance("Stop there."));
        w.runner.dispatch({ type: "talk-down" });
        await until(() => w.s().capture.kind === "open", "capture reopens after the flush");
        assert.equal(w.audio.lastPlayback.heardText, "Hello", "Audio's lower bound covers one word");
        w.runner.dispatch({ type: "talk-up" });
        server.replies.push(text("Stopped."));
        const body = await requested(w, first + 2, "the request after barge-in");
        assert.deepEqual(body.messages.slice(1).map(message => [message.role, message.content]), [
            ["user", "What time is it?"], ["assistant", "Hello there. The time is noon."],
            ["user", heardOnly("Hello") + "\n\nStop there."]], "the brain is told exactly the heard prefix");
        assert.deepEqual(control.spoken.slice(0, 2), ["Hello there.", "The time is noon."]);
        await until(() => w.s().turn.kind === "none" && w.s().playback.kind !== "idle", "the answer speaks");
        await playOut(w);
        const third = await say(w, utterance("Next."));
        server.replies.push(text(""));
        const later = await requested(w, third + 1, "the turn after");
        assert.equal(user(later).at(-1), "Next.", "the heard prefix is told once");
    });

    // Barge-in mid-stream: the cancelled turn stays unanswered and its
    // partial reply never enters history; the server sees the stream close.
    await run("barge-in-streaming", async w => {
        const first = await say(w, utterance("Tell me a story."));
        await requested(w, first + 1, "first request");
        const held = gate();
        server.replies.push(text("First part. ", { wait: held.wait }, "Second part."));
        await feeding(w, 2 * Fixture.WORD_FRAMES);
        await advance(w, 6);
        control.utterances.push(utterance("Enough."));
        w.runner.dispatch({ type: "talk-down" });
        await until(() => w.s().capture.kind === "open", "capture reopens after cancel and flush");
        await server.requests[first].closed;
        held.open();
        w.runner.dispatch({ type: "talk-up" });
        server.replies.push(text("Fine."));
        const body = await requested(w, first + 2, "the request after barge-in");
        assert.deepEqual(body.messages.slice(1).map(message => [message.role, message.content]), [
            ["user", "Tell me a story."], ["user", heardOnly("First") + "\n\nEnough."]]);
        assert.equal(w.s().brain.kind, "acquired", "the interrupted conversation keeps its brain");
    });

    // Cancel during thinking, before any audio: the heard text is empty.
    await run("cancel-thinking", async w => {
        const first = await say(w, utterance("Open the door."));
        await requested(w, first + 1, "first request");
        const held = gate();
        server.replies.push(pause(held));
        control.utterances.push(utterance("Never mind."));
        w.runner.dispatch({ type: "talk-down" });
        await server.requests[first].closed;
        await until(() => w.s().capture.kind === "open", "capture reopens after the cancel acknowledgement");
        assert.equal(w.audio.lastPlayback, null, "no audio played before the interruption");
        held.open();
        w.runner.dispatch({ type: "talk-up" });
        server.replies.push(text("Okay."));
        const body = await requested(w, first + 2, "the request after cancel");
        assert.deepEqual(user(body), ["Open the door.", INTERRUPTED + "\n\nNever mind."], "the brain is told it heard nothing");
    });

    // A tool call goes through the real router to a stand-in executor and
    // returns as one tool-results turn with the local class's restated rule.
    await run("tool-round", async w => {
        const first = await say(w, utterance("Focus the editor."));
        server.replies.push(calls({ id: "call_1", name: "windows_focus", arguments: { window: "0x1f" } }), text("Focused it."));
        const body = await requested(w, first + 2, "the tool-results request");
        await requested(w, first + 1, "first request");
        assert.deepEqual(w.executions.map(call => [call.id, call.args]), [["windows.focus", { window: "0x1f" }]]);
        const after = require(path.join(kit.folder, "backend/Guidance.js")).compose("chained", "local", "").afterToolResult;
        assert.deepEqual(body.messages.slice(-3).map(message => [message.role, message.content]), [
            ["assistant", null], ["tool", "focused 0x1f"], ["system", after]], "the local class restates its rule after results");
        await until(() => w.s().playback.kind === "playing", "the final reply speaks");
        await playOut(w);
        assert.deepEqual(control.spoken, ["Focused it."]);
        assert.deepEqual(w.captions.map(row => row.slice(2)), [["partial", 1, "Focused it."], ["final", 2, "Focused it."]],
            "a tool round's reply is captioned once, at its end");
        assert.deepEqual(w.faults, []);
    });

    // A segment closes at the wire's bound; a failed reply closes its words.
    await run("caption-segments", async w => {
        const first = await say(w, utterance("What time is it?"));
        await requested(w, first + 1, "first request");
        server.replies.push(text("It is noon. ", "Anything else?"));
        await until(() => w.s().turn.kind === "none", "the reply completes");
        const second = await say(w, utterance("And tomorrow?"));
        await requested(w, second + 1, "second request");
        server.replies.push(text("Bye now. More").slice(0, 2));
        await until(() => w.s().fault.kind === "error", "the cut reply fails");
        assert.deepEqual(w.captions.map(row => row.slice(2)), [
            ["partial", 1, "It is noon."], ["final", 2, "It is noon."], ["partial", 3, "Anything els"],
            ["final", 4, "Anything els"], ["partial", 5, "e?"], ["final", 6, "e?"],
            ["partial", 7, "Bye now."], ["final", 8, "Bye now."]], "segments split at the bound");
    }, { captionLimit: 12 });

    // An interrupted call that runs on is answered "running" and its real
    // outcome reaches the next user turn, never the turn it interrupted; a
    // call that never started is answered "not-started".
    await run("stale-outcome", async w => {
        const first = await say(w, utterance("Focus the editors."));
        server.replies.push(calls({ id: "call_1", name: "windows_focus", arguments: { window: "0x1f" } },
            { id: "call_2", name: "windows_focus", arguments: { window: "0x2b" } }));
        await until(() => w.held.length === 1, "the stand-in executor holds the first call");
        control.utterances.push(utterance("Wait."));
        w.runner.dispatch({ type: "talk-down" });
        await until(() => w.s().capture.kind === "open", "capture reopens while the tool runs");
        const later = gate();
        server.replies.push([...pause(later), ...text("Waiting.").slice(1)]);
        w.runner.dispatch({ type: "talk-up" });
        const body = await requested(w, first + 2, "the request after the interruption");
        assert.deepEqual(body.messages.slice(2).map(message => [message.role, message.content]), [
            ["assistant", null], ["tool", "{\"kind\":\"interrupted\",\"outcome\":\"running\"}"],
            ["tool", "{\"kind\":\"interrupted\",\"outcome\":\"not-started\"}"],
            ["user", INTERRUPTED + "\n\nWait."]], "a running call and an unstarted one get distinct answers");
        w.held[0]({ outcome: "completed", content: "focused late" });
        await turn();
        later.open();
        await until(() => w.s().turn.kind === "none" && w.s().playback.kind !== "idle", "the second reply speaks");
        await playOut(w);
        assert.deepEqual(w.faults, []);
        assert.equal(w.s().fault.kind, "none", "the late outcome reached no live turn");
        assert.equal(w.executions.length, 1, "the unrouted call never started");
        const third = await say(w, utterance("Thanks."));
        server.replies.push(text(""));
        const last = await requested(w, third + 1, "the third request");
        assert.equal(user(last).at(-1), "[late result] Your interrupted call windows.focus ended completed: focused late\n\nThanks.",
            "the real outcome reaches the next user turn once");
        const fourth = await say(w, utterance("Bye."));
        server.replies.push(text(""));
        assert.equal(user(await requested(w, fourth + 1, "the fourth request")).at(-1), "Bye.");
    }, { holdTools: true });

    // History taints later turns: a screen read in one turn makes the next
    // turn's persistent call ask for approval.
    await run("history-taint", async w => {
        const first = await say(w, utterance("What is on screen?"));
        server.replies.push(calls({ id: "call_1", name: "vision_screen", arguments: {} }), text(""));
        await requested(w, first + 2, "the tool-results request");
        await until(() => w.s().turn.kind === "none", "the first turn completes");
        const second = await say(w, utterance("Close it."));
        server.replies.push(calls({ id: "call_2", name: "windows_close", arguments: { window: "0x2a" } }));
        await requested(w, second + 1, "the second request");
        await until(() => w.s().approval.kind === "held" || w.executions.length > 1, "the router judges the call");
        assert.equal(w.s().approval.kind, "held", "earlier screen content still taints the conversation");
        assert.deepEqual(w.executions.map(call => call.id), ["vision.screen"]);
    });

    // Toggle mode: capture reopens while thinking; that utterance is not the
    // next turn's, so the second turn binds its own capture.
    await run("toggle-turns", async w => {
        control.utterances.push(utterance("First turn.", [], null, { afterFrames: 3 }),
            utterance("unbound while thinking", [], null, { afterFrames: 1 }),
            utterance("Second turn.", [], null, { afterFrames: 3 }),
            utterance("never ends", [], null, { afterFrames: 100000 }));
        const before = server.requests.length;
        const thinkingCapture = gate();
        server.replies.push([...pause(thinkingCapture), ...text("One.").slice(1)], text("Two."));
        w.runner.dispatch({ type: "talk-down" });
        const body = await requested(w, before + 1, "the first toggle turn");
        assert.deepEqual(user(body), ["First turn."]);
        await until(() => control.utterances.length === 2, "capture reopens while the brain thinks");
        thinkingCapture.open();
        await until(() => w.s().playback.kind === "playing", "the first reply speaks");
        await playOut(w);
        const next = await requested(w, before + 2, "the second toggle turn");
        assert.equal(user(next).at(-1), "Second turn.");
    }, { mode: "toggle" });

    // A transcription that fails after its capture closed ends its turn.
    await run("transcribe-failure", async w => {
        control.utterances.push(utterance("lost", [], null, { failAfterClose: true }));
        const before = server.requests.length;
        w.runner.dispatch({ type: "talk-down" });
        await until(() => w.s().capture.kind === "open", "capture opens");
        w.runner.dispatch({ type: "talk-up" });
        await until(() => w.s().turn.kind !== "collecting", "the failure reaches the turn");
        assert.deepEqual({ ...w.s().fault }, { kind: "error", reason: "speech=fixture-failed", retry: 0 });
        assert.equal(server.requests.length, before);
    });

    // The thinking deadline bounds the brain, not speech: a reply that plays
    // longer than it leaves no timeout.
    await run("long-speech", async w => {
        const first = await say(w, utterance("Read a long list."));
        await requested(w, first + 1, "first request");
        server.replies.push(text("One. ", "Two. ", "Three."));
        await until(() => w.s().turn.kind === "none", "the brain finishes while speech still waits on playback");
        assert.equal(w.s().playback.kind, "playing");
        w.advanceRunner(120000);
        assert.equal(w.s().fault.kind, "none", "no thinking timeout fires during speech");
        await playOut(w);
    });

    // Conversation end closes brain, transport and speech adapters; the next
    // conversation starts with fresh history and a new recipient set.
    await run("conversation-end", async w => {
        const first = await say(w, utterance("Count to ten."));
        await requested(w, first + 1, "first request");
        const held = gate();
        server.replies.push(pause(held));
        w.runner.dispatch({ type: "stop" });
        await server.requests[first].closed;
        held.open();
        assert.equal(control.closed, 1, "the speech adapter is closed");
        const old = control.opened[0];
        await assert.rejects(old.net.request({ content: "x", labels: ["speech"] }, { url: "http://127.0.0.1:" + PORT + "/v1" }),
            { message: "jarvis: net=closed" }, "the conversation's transport is closed");
        await until(() => w.s().brain.kind === "closed", "Session closes the brain owner");
        const second = await say(w, utterance("Hello again."));
        server.replies.push(text(""));
        const body = await requested(w, second + 1, "the next conversation");
        assert.deepEqual(user(body), ["Hello again."], "a new conversation has fresh history");
        assert.notEqual(control.opened[1].recipients, old.recipients);
    });

    // A session-setting change ends the conversation and drops its context
    // and recipient set before a new one starts.
    await run("settings-change", async w => {
        const first = await say(w, utterance("Remember blue."));
        server.replies.push(text(""));
        await requested(w, first + 1, "first request");
        await until(() => w.s().turn.kind === "none", "the first turn completes");
        const old = control.opened[0];
        assert.deepEqual(w.configure({ mode: "hold", microphone: "", speaker: "", brain: "other-account" }), { kind: "ready" });
        await assert.rejects(old.net.request({ content: "x", labels: ["speech"] }, { url: "http://127.0.0.1:" + PORT + "/v1" }),
            { message: "jarvis: net=closed" }, "the old transport closes at the change");
        const second = await say(w, utterance("What did I say?"));
        server.replies.push(text(""));
        const body = await requested(w, second + 1, "the request after the change");
        assert.deepEqual(user(body), ["What did I say?"], "old context does not cross the change");
        assert.equal(control.opened[1].recipients.brain.account, "other-account");
    });

    // Release markers: a remote speech recipient makes the set non-offline,
    // so a clipboard result travels as its marker and the ask is audited.
    await run("release-markers", async w => {
        const first = await say(w, utterance("Read my clipboard."));
        server.replies.push(calls({ id: "call_1", name: "clipboard_read", arguments: {} }), text(""));
        const body = await requested(w, first + 2, "the tool-results request");
        assert.equal(body.messages.find(message => message.role === "tool").content, "[withheld: clipboard content]");
        assert.equal(JSON.stringify(body).includes("clipboard words"), false);
        assert.ok(w.rows().some(row => row.kind === "release" && row.decision === "ask"), "the ask decision is audited");
    }, { fixture: { recipients: [{ kind: "network", provider: "scripted-voice", account: "fixture", origin: "http://192.0.2.1:9" }] } });

    // A failed audit write refuses the brain request and the speech text.
    await run("audit-refusal", async w => {
        const block = () => {
            fs.renameSync(path.join(w.state, "audit"), path.join(w.state, "audit-saved"));
            fs.writeFileSync(path.join(w.state, "audit"), "not a directory\n");
        };
        control.utterances.push(utterance("Hello."));
        const before = server.requests.length;
        w.runner.dispatch({ type: "talk-down" });
        await until(() => w.s().capture.kind === "open", "capture opens");
        block();
        w.runner.dispatch({ type: "talk-up" });
        await until(() => w.s().fault.kind === "error", "the turn fails");
        assert.equal(w.s().fault.reason, "engine=audit-write");
        // The next request to arrive must be a later turn's: none left first.
        fs.rmSync(path.join(w.state, "audit"));
        fs.renameSync(path.join(w.state, "audit-saved"), path.join(w.state, "audit"));
        assert.deepEqual(w.configure({ mode: "hold", microphone: "", speaker: "", brain: "other-account" }), { kind: "ready" });
        await say(w, utterance("Again."));
        server.replies.push(text(""));
        assert.deepEqual(user(await requested(w, before + 1, "the next turn")), ["Again."],
            "no request left without its audit record");
    });
    await run("audit-refusal-speech", async w => {
        const first = await say(w, utterance("Hello."));
        await requested(w, first + 1, "first request");
        const held = gate();
        server.replies.push([...pause(held), ...text("Hi there.").slice(1)]);
        fs.renameSync(path.join(w.state, "audit"), path.join(w.state, "audit-saved"));
        fs.writeFileSync(path.join(w.state, "audit"), "not a directory\n");
        held.open();
        await until(() => w.s().fault.kind === "error", "the turn fails");
        assert.equal(w.s().fault.reason, "engine=audit-write");
        assert.deepEqual(control.spoken, [], "no text reaches speech without its audit record");
        assert.deepEqual(w.captions, [], "no text is captioned without its release");
    });

    // The plan's context bound: the fortieth turn is sent, the next fails.
    await run("context-bound", async w => {
        for (let index = 1; index <= 40; index++) {
            const before = await say(w, utterance("turn " + index));
            server.replies.push(text(""));
            await requested(w, before + 1, "turn " + index);
            await until(() => w.s().turn.kind === "none", "turn " + index + " completes");
        }
        const before = await say(w, utterance("one more"));
        await until(() => w.s().conversation.kind === "ended", "the bound ends the conversation");
        assert.equal(w.s().fault.kind, "none", "the bound leaves no fault");
        assert.equal(server.requests.length, before, "no request past the bound");
        const fresh = await say(w, utterance("A new start."));
        server.replies.push(text(""));
        assert.deepEqual(user(await requested(w, fresh + 1, "the next conversation")), ["A new start."]);
    });

    // Playback backpressure pauses the brain stream; no sentence is dropped.
    await run("backpressure", async w => {
        const first = await say(w, utterance("Read a long list."));
        await requested(w, first + 1, "first request");
        const sentences = Array.from({ length: 40 }, (_, index) => "Item number " + (index + 1) + ".");
        server.replies.push(text(...sentences.map(sentence => sentence + " ")));
        // Nothing advances the playback clock: the source fills to its mark.
        await until(() => w.audio.playbackFeed !== null
            && w.audio.playbackFeed.readableLength >= w.audio.playbackFeed.readableHighWaterMark, "the source fills");
        await until(() => w.s().turn.kind === "none", "the brain is read to its end");
        // Audio holds one chunk and the adapter one sentence beyond the mark.
        const bound = w.audio.playbackFeed.readableHighWaterMark + 2;
        assert.ok(control.spoken.length <= bound, "a stalled player pauses synthesis: " + control.spoken.length);
        await playOut(w);
        assert.equal(control.spoken.length, 40);
        assert.deepEqual(w.faults, []);
        assert.equal(w.s().fault.kind, "none");
    });

    // A partial revision that does not increase is an adapter fault.
    await run("partial-revision", async w => {
        control.utterances.push(utterance("x", [], [{ kind: "partial", text: "a", rev: 2 },
            { kind: "partial", text: "b", rev: 1 }, { kind: "final", text: "x" }]));
        const before = server.requests.length;
        w.runner.dispatch({ type: "talk-down" });
        await until(() => w.s().fault.kind === "error", "the capture fails");
        assert.equal(w.s().fault.reason, "provider-disconnected");
        assert.equal(server.requests.length, before);
    });

    // Mute during capture retires the transcription without a final.
    await run("mute-capture", async w => {
        control.utterances.push(utterance("private words", ["private"]));
        const before = server.requests.length;
        w.runner.dispatch({ type: "talk-down" });
        await until(() => w.partials.at(-1) === "private", "transcription runs");
        w.runner.dispatch({ type: "mute-toggle" });
        await until(() => w.s().mute.kind === "on", "mute completes");
        await until(() => control.aborted === 1, "the transcription is abandoned");
        assert.equal(server.requests.length, before, "muted words never reach the brain");
    });
}

// Selection: the first ready speech row, then the saved brain account, its
// declared model and provider row. Each refusal names its cause.
function selection(Engine) {
    const resolved = { id: "a", provider: "ollama", label: "local",
        source: { kind: "local", origin: "http://127.0.0.1:" + PORT }, model: "fixture-model" };
    const configure = (settings, resolve, ready) => {
        Fixture.reset({ ready });
        let answer;
        assert.doesNotThrow(() => {
            answer = Engine.create({ accounts: () => ({ secrets: null, resolve }), captionLimit: 1 }).configure({ brain: "a", ...settings });
        }, "selection answers with a cause");
        return answer;
    };
    for (const [settings, resolve, ready, cause] of [
        [{}, () => resolved, false, "speech=fixture-off"],
        [{ brain: "" }, () => resolved, true, "brain=unselected"],
        [{}, () => null, true, "brain=account-unavailable"],
        [{}, () => ({ ...resolved, model: "" }), true, "brain=model-required"]])
        assert.deepEqual(configure(settings, resolve, ready), { kind: "unconfigured", cause }, cause);
    assert.deepEqual(configure({}, () => { throw new Error("jarvis-keys: references=json"); }, true),
        { kind: "unconfigured", cause: "brain=accounts-unreadable", detail: "jarvis-keys: references=json" },
        "a reader's keyed failure keeps its cause");
    Fixture.reset();
    assert.throws(() => Engine.create({ accounts: () => ({ resolve: () => { throw new TypeError("defect"); } }), captionLimit: 1 })
        .configure({ brain: "a" }), TypeError, "a defect is not a configuration cause");
    assert.deepEqual(configure({}, () => resolved, true), { kind: "ready" });
    // A subscription's program chooses its own model; its account names its directory.
    assert.deepEqual(configure({}, () => ({ id: "c", provider: "codex", label: "default",
        source: { kind: "cli", directory: "/home/fixture/.codex" }, model: "" }), true), { kind: "ready" });
}

world(async () => {
    const stock = require(path.join(tree, "shell/plugins/vgs.jarvis/backend/ChainedEngine.js"));
    assert.deepEqual(stock.create({ accounts: () => assert.fail("no account is read without a speech row"), captionLimit: 1 })
        .configure({ brain: "a" }), { kind: "unconfigured", cause: "speech=no-adapter" }, "the stock daemon stays unconfigured");
    const server = Fixture.brain(PORT);
    await server.ready;
    const root = process.env.JARVIS_TEST_ROOT;
    let controls = 0;
    try {
        selection(Fixture.copy(root).Engine);
        for (const [name, needle, replacement = ""] of [
            ["speech-not-ready", 'if (speech.kind !== "ready") return speech;'],
            ["first-speech-cause", 'if (speech.cause === "speech=no-adapter") speech = answer;'],
            ["accounts-unreadable", 'return unconfigured("brain=accounts-unreadable", error.message);'],
            ["unselected", 'if (settings.brain === "") return unconfigured("brain=unselected");'],
            ["account-unavailable", 'if (account === null) return unconfigured("brain=account-unavailable");'],
            ["model-required", 'if (account.model === "" && account.source.kind !== "cli") return unconfigured("brain=model-required");'],
            ["subscription-model", ' && account.source.kind !== "cli") return unconfigured("brain=model-required");',
                ') return unconfigured("brain=model-required");'],
            ["harness-driver", '    "codex-app-server": CodexHarness });', "    });"]]) {
            const { Engine } = Fixture.copy(root, [[needle, replacement]]);
            assert.throws(() => selection(Engine), assert.AssertionError, name + " must turn red");
            console.log("control=" + name + " detected");
            controls++;
        }
        await cases(Fixture.copy(root), server);
        assert.deepEqual(server.faults, [], "every request matched the pinned schema");
        // Each control plants one defect in a disposable engine copy.
        const plants = [
            ["router-offers", "tools: router.offer()", "tools: []", "turn-loop"],
            ["heard-omitted", "if (c.heard !== null) items.push(heardItem(c.heard));", "", "barge-in"],
            ["heard-once", "            c.heard = null;\n", "", "barge-in"],
            ["full-reply-heard", 'heard(c, turn, report === null ? "" : report.heardText);',
                'heard(c, turn, "Hello there. The time is noon.");', "barge-in"],
            ["cancel-heard", '            heard(c, turn, "");\n', "", "cancel-thinking"],
            ["partial-to-brain", 'utterance.collection?.done("partial", event.text);', 'utterance.collection?.done("final", event.text);', "turn-loop"],
            ["speakable-bypass", "for (const sentence of text.push(event.text)) say(c, turn, sentence);",
                "text.push(event.text); say(c, turn, event.text);", "turn-loop"],
            ["unlabelled-frames", 'return { value: Policy.item(chunk, ["speech"]), done: false };',
                'return { value: Policy.item(chunk, ["desktop"]), done: false };', "turn-loop"],
            ["result-identity", 'if (turn !== null && turn.op === value.op && turn.phase === "routing" && turn.routing?.id === id) {',
                "if (turn !== null) {", "stale-outcome"],
            ["interrupted-answers", "if (routing && c.brain !== null) c.brain.record(", "if (false) c.brain.record(", "stale-outcome"],
            ["not-started", 'return router.interrupted(call, "not-started");', 'return router.interrupted(call, "running");', "stale-outcome"],
            ["late-result", "c.results.push(lateItem(late.call, value.outcome, item));", "void lateItem;", "stale-outcome"],
            ["history-taint", "router.observe(turn, reply.release.labels);", "void reply;", "history-taint"],
            ["toggle-adoption", 'c.unbound !== null && c.unbound.state === "running" ? c.unbound : null',
                "c.unbound", "toggle-turns"],
            ["collect-failure", "else if (collecting(c, utterance.collection)) utterance.collection.failed(keyed(error));",
                "else if (false) utterance.collection.failed(keyed(error));", "transcribe-failure"],
            ["speech-gates-brain", 'turn.speech?.end();\n                        concluded(c, turn);',
                'turn.speech?.end();\n                        await new Promise(resolve => turn.speech.readable.once("close", resolve));\n                        concluded(c, turn);', "long-speech"],
            ["net-not-closed", "        c.net.close();\n", "", "conversation-end"],
            ["observe-teardown", "observe(s) { if (conversation !== null && s.gen !== conversation.gen) end(); },", "observe(s) {},", "settings-change"],
            ["audit-skipped", '"pending"), start);\n        if (result.kind !== "started") fail("audit-write");\n        return result.value;',
                '"pending"), () => {});\n        void result;\n        return start();', "audit-refusal"],
            ["after-tool-rule", "...(after === null ? {} : { instructions: after }),", "", "tool-round"],
            ["context-clean-end", 'turn.done(reason === "brain=context-limit" ? "brain-ended" : "brain-failed", { reason });',
                'turn.done("brain-failed", { reason });', "context-bound"],
            ["readable-backpressure", "if (!readable.push(step.value)) await wanted.wait();", "readable.push(step.value);", "backpressure"],
            ["partial-revision", "event.rev <= rev", "false", "partial-revision"],
            ["end-aborts-transcription", "            if (utterance) utterance.abort();", "            void utterance;", "mute-capture"],
            ["caption-dropped", "        caption(c, turn, sentence);\n", "", "turn-loop"],
            ["caption-final", 'concluded(c, turn);\n                        turn.done("brain-done");', 'turn.done("brain-done");', "turn-loop"],
            ["caption-revision", "rev: ++c.rev", "rev: 1", "turn-loop"],
            ["caption-before-release", "        transfer(c, turn, item, () => {\n            if (turn.speech === null) {",
                "        caption(c, turn, sentence);\n        transfer(c, turn, item, () => {\n            if (turn.speech === null) {", "audit-refusal-speech"],
            ["caption-separator", "        if (turn.caption.length + 1 >= captionLimit) concluded(c, turn);\n", "", "caption-segments"],
            ["caption-bound", "const room = captionLimit - turn.caption.length;", "const room = Infinity;", "caption-segments"],
            ["caption-failure-final", "        concluded(c, turn);\n        const reason = keyed(error);", "        const reason = keyed(error);", "caption-segments"]
        ];
        for (const [name, needle, replacement, scenario] of plants) {
            // The copy asserts its match outside the measured run.
            const kit = Fixture.copy(root, [[needle, replacement]]);
            let failure = null;
            try { await cases(kit, server, scenario); }
            catch (error) { failure = error; }
            assert.ok(failure instanceof assert.AssertionError, name + " must turn an assertion red: " + failure);
            console.log("control=" + name + " detected: " + failure.message.split("\n")[0]);
            controls++;
        }
        console.log("test-jarvis-engine: ok requests=" + server.requests.length + " controls=" + controls);
    } finally { await server.close(); }
// Bounds a hung world: each control reruns a case with real children.
}, 900000).catch(error => { console.error(error); process.exitCode = 1; });
