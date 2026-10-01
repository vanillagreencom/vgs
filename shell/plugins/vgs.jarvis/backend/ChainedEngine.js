// One chained conversation: speech to text, brain, Speakable, text to speech.
// Session owns identity and deadlines, Audio owns pacing and heard accounting,
// WireBrain owns history and ToolRouter owns actions. This owner connects them
// per conversation and keeps the heard prefix that the next turn reports.
// Contract: docs/architecture/jarvis-engine.md.
"use strict";
const { Readable, Writable } = require("node:stream");
const Policy = require("./Policy.js");
const Providers = require("./Providers.js");
const Net = require("./net.js");
const Guidance = require("./Guidance.js");
const Speakable = require("./Speakable.js");
const OpenAIChat = require("./OpenAIChat.js");
const AnthropicMessages = require("./AnthropicMessages.js");

// Speech adapter rows in selection order. A row is {select({settings,
// accounts})} answering {kind:"ready", recipients, open({net, recipients})}
// or {kind:"unconfigured", cause}. The local and ElevenLabs rows add theirs.
const SPEECH = Object.freeze({});
const DRIVERS = Object.freeze({ "openai-chat": OpenAIChat, "anthropic-messages": AnthropicMessages });
// The hello carries no language setting; empty selects English.
const LANGUAGE = "";
// Object-mode chunks queued toward Audio, below its playback allowance.
const SPEECH_CHUNKS = 16;
// Released sentences waiting for synthesis before the brain stream pauses.
const SENTENCES = 2;
// Capture bytes held for transcription before Audio sees backpressure.
const CAPTURE_BYTES = 16 * 1024;

function fail(code) { throw new Error("jarvis: engine=" + code); }
function unconfigured(cause) { return { kind: "unconfigured", cause }; }
// Session's fault carries the producer's keyed cause, never other text.
function keyed(error) {
    const message = error?.message ?? "";
    return /^jarvis(?:-[a-z]+)?: [a-z-]+=[^\n]*$/.test(message)
        ? message.replace(/^jarvis: /, "").slice(0, 180) : "engine=unexpected";
}

// One wake point per waiter; notify releases every current waiter.
function signal() {
    let waiters = [];
    return {
        wait: () => new Promise(resolve => waiters.push(resolve)),
        notify() { const current = waiters; waiters = []; for (const resolve of current) resolve(); }
    };
}

/**
 * Choose the conversation plan from snapshot settings. The first ready speech
 * row wins; the brain comes from the saved account through Accounts, its
 * declared default model, the provider table and the key reference.
 */
function select(settings, accounts) {
    let speech = unconfigured("speech=no-adapter");
    for (const [id, row] of Object.entries(SPEECH)) {
        const answer = row.select({ settings, accounts });
        if (answer.kind === "ready") { speech = { ...answer, id }; break; }
        if (answer.kind !== "unconfigured") fail("speech-row");
        if (speech.cause === "speech=no-adapter") speech = answer;
    }
    if (speech.kind !== "ready") return speech;
    if (settings.brain === "") return unconfigured("brain=unselected");
    let judge, account;
    try {
        judge = accounts();
        account = judge.resolve(settings.brain);
    } catch { return unconfigured("brain=accounts-unreadable"); }
    if (account === null) return unconfigured("brain=account-unavailable");
    if (account.model === "") return unconfigured("brain=model-required");
    const provider = Providers.select(account.provider);
    if (!Object.hasOwn(DRIVERS, provider.driver)) fail("driver");
    const target = Net.endpoint(provider.base);
    return { kind: "ready", speech, brain: { provider, model: account.model,
        key: account.source.kind === "keyring" ? { secrets: judge.secrets, reference: account.source.reference } : null,
        recipient: { kind: "network", provider: provider.id, account: account.id, origin: target.origin },
        guidance: Guidance.compose("chained", target.loopback ? "local" : "text", LANGUAGE) } };
}

/**
 * create({session, state, audit, router, accounts, policy, fault}) owns the
 * daemon's chained conversations. session is the Session judge and state
 * returns its current record;
 * audit is the daemon's writer; router supplies offer and route; accounts
 * returns an Accounts judge; policy returns {profile, cloudVision}; fault
 * reports a speech failure no capture owner remains to carry.
 */
function create({ session, state, audit, router, accounts, policy, fault }) {
    let plan = unconfigured("engine=starting");
    let conversation = null;
    let retired = null;
    let closed = false;

    // An asked or withheld item travels as its marker; its decision is kept.
    function record(c, identity, labels, decision) {
        const result = audit.record({ kind: "release", gen: identity.gen, op: identity.op, tool: "release",
            args: { labels, recipients: c.recipients }, effect: null, decision, confirmed: "none", outcome: "completed" });
        if (result.kind !== "recorded") fail("audit-write");
    }
    // Every transfer to the conversation's recipients is audited first.
    function transfer(c, identity, labels, start) {
        const result = audit.before({ kind: "release", gen: identity.gen, op: identity.op, tool: "release",
            args: { labels, recipients: c.recipients }, effect: null, decision: "send", confirmed: "none",
            outcome: "pending" }, start);
        if (result.kind !== "started") fail("audit-write");
        return result.value;
    }

    function open(gen) {
        if (closed) fail("closed");
        if (plan.kind !== "ready") fail("unconfigured");
        const facts = policy();
        const recipients = Policy.recipients({ conversation: "jarvis-" + gen, profile: facts.profile,
            cloudVision: facts.cloudVision, brain: plan.brain.recipient, speech: plan.speech.recipients });
        const net = Net.create(recipients);
        let speech;
        try { speech = plan.speech.open({ net, recipients }); }
        catch (error) { net.close(); throw error; }
        return { gen, plan, recipients, net, speech, brain: null, owner: null, grants: [], heard: null,
            turn: null, last: null, collection: null, unbound: null };
    }
    // observe() ends a conversation before any effect of a newer generation.
    function current(gen) {
        if (gen !== state().gen) fail("stale-conversation");
        if (conversation !== null && conversation.gen !== gen) fail("conversation-generation");
        if (conversation === null) conversation = open(gen);
        return conversation;
    }
    // Drop the context, the recipient set and its transport before another
    // conversation can start. Late cancel acknowledgments wait for closure.
    function end() {
        const c = conversation;
        if (c === null) return;
        conversation = null;
        if (c.turn !== null) stop(c.turn);
        if (c.last !== null) c.last.speech?.end();
        for (const transcription of [c.collection?.transcription, c.unbound])
            if (transcription) transcription.abort();
        const brain = c.brain;
        c.brain = null;
        const quiet = brain === null ? Promise.resolve() : brain.cancel();
        brain?.close();
        c.speech.close();
        c.net.close();
        retired = { gen: c.gen, closed: quiet };
    }
    function live(gen, op, region, kinds) {
        return session.live(state(), { gen, op }, region, kinds);
    }

    // Speech to text. The capture sink exists while Audio holds the
    // recorder; one transcription yields partials and one final.
    function transcription(c, e) {
        let held = null;
        let finished = false;
        let aborted = false;
        let released = false;
        let output = null;
        const wake = signal();
        const t = { collection: null, sink: null, abort() {
            if (aborted) return;
            aborted = true;
            held = null;
            wake.notify();
            void output?.return?.();
        } };
        const sink = new Writable({
            highWaterMark: CAPTURE_BYTES,
            // Frames after the adapter stopped reading have no consumer.
            write(chunk, encoding, done) {
                if (released || aborted) { done(); return; }
                held = { chunk, done };
                wake.notify();
            },
            final(done) { finished = true; wake.notify(); done(); },
            // Audio's teardown ends the utterance. A conversation that ended
            // with it, as by mute or stop, aborts the transcription in end().
            destroy(error, done) {
                finished = true;
                held = null;
                wake.notify();
                done(error);
            }
        });
        t.sink = sink;
        const frames = { [Symbol.asyncIterator]() { return { async next() {
            for (;;) {
                if (aborted) return { value: undefined, done: true };
                if (held !== null) {
                    const { chunk, done } = held;
                    held = null;
                    done();
                    return { value: chunk, done: false };
                }
                if (finished) return { value: undefined, done: true };
                await wake.wait();
            }
        }, async return() {
            released = true;
            held?.done();
            held = null;
            return { value: undefined, done: true };
        } }; } };
        async function run() {
            let rev = 0;
            try {
                transfer(c, e, ["speech"], () => { output = c.speech.transcribe(frames)[Symbol.asyncIterator](); });
                for (;;) {
                    const step = await output.next();
                    if (aborted) return;
                    if (step.done) fail("transcript-unfinished");
                    const event = step.value;
                    if (event === null || typeof event !== "object" || typeof event.text !== "string") fail("transcript");
                    if (event.kind === "partial") {
                        if (!Number.isSafeInteger(event.rev) || event.rev <= rev) fail("transcript-revision");
                        rev = event.rev;
                        deliver(t, "partial", event.text);
                    } else if (event.kind === "final") {
                        deliver(t, "final", event.text);
                        void output.return?.();
                        return;
                    } else fail("transcript");
                }
            } catch (error) {
                if (aborted) return;
                aborted = true;
                if (!sink.destroyed) sink.destroy(error);
                else fault("speech-transcribe: " + keyed(error));
            }
        }
        void run();
        return t;
    }
    function deliver(t, kind, text) {
        if (t.collection !== null) t.collection.done(kind, text);
    }

    // Text to speech for one brain turn: one Readable for Audio, fed by the
    // adapter from released sentences. Each stage waits on the next one.
    function speech(c) {
        const sentences = [];
        const input = signal(), room = signal(), wanted = signal();
        let ended = false;
        const readable = new Readable({ objectMode: true, highWaterMark: SPEECH_CHUNKS,
            read() { wanted.notify(); } });
        // Audio reports a failed source as a failed playback, including one
        // destroyed before Audio attached its own listener.
        readable.on("error", () => {});
        readable.once("close", () => { ended = true; input.notify(); room.notify(); wanted.notify(); });
        const sentenceInput = { [Symbol.asyncIterator]() { return { async next() {
            for (;;) {
                if (sentences.length !== 0) {
                    const value = sentences.shift();
                    room.notify();
                    return { value, done: false };
                }
                if (ended) return { value: undefined, done: true };
                await input.wait();
            }
        }, async return() { ended = true; return { value: undefined, done: true }; } }; } };
        async function pump() {
            const output = c.speech.speak(sentenceInput)[Symbol.asyncIterator]();
            try {
                for (;;) {
                    const step = await output.next();
                    if (readable.destroyed) { void output.return?.(); return; }
                    if (step.done) { readable.push(null); return; }
                    if (!readable.push(step.value)) await wanted.wait();
                }
            } catch (error) { readable.destroy(error); }
        }
        void pump();
        return {
            readable, handed: false,
            queue(sentence) { sentences.push(sentence); input.notify(); },
            async room() {
                while (sentences.length >= SENTENCES && !ended && !readable.destroyed) await room.wait();
            },
            end() { ended = true; input.notify(); }
        };
    }

    async function say(c, t, sentence) {
        if (t.stopped) return;
        const item = Policy.item(sentence, [...t.labels]);
        // A reply carries only labels its request sent to this same set.
        if (Policy.release(item, c.recipients, c.grants).kind !== "send") fail("speech-release");
        transfer(c, t, item.labels, () => {
            if (t.speech === null) {
                t.speech = speech(c);
                t.done("play", { interruptible: true });
            }
            t.speech.queue(sentence);
        });
        t.spoken.push(sentence);
        await t.speech.room();
    }

    function stop(t) {
        t.stopped = true;
        t.speech?.end();
    }
    function failed(c, t, error) {
        if (t.stopped) return;
        stop(t);
        if (c.turn === t) c.turn = null;
        t.done("brain-failed", { reason: keyed(error) });
    }

    async function respond(c, t, turn) {
        try {
            const reply = c.brain.send(turn, c.grants);
            if (reply.release.needed.length !== 0) record(c, t, reply.release.needed, "ask");
            if (reply.release.withheld.length !== 0) record(c, t, reply.release.withheld, "withhold");
            for (const label of reply.release.labels) t.labels.add(label);
            const events = reply.events[Symbol.asyncIterator]();
            const text = Speakable.create(LANGUAGE);
            const calls = [];
            // A request with no released content refuses before it is sent.
            let step = await (reply.release.labels.length === 0 ? events.next()
                : transfer(c, t, reply.release.labels, () => events.next()));
            for (; !step.done; step = await events.next()) {
                if (t.stopped) return;
                const event = step.value;
                switch (event.kind) {
                case "text":
                    for (const sentence of text.push(event.text)) await say(c, t, sentence);
                    break;
                case "tool-call": calls.push(event); break;
                case "done":
                    for (const sentence of text.finish()) await say(c, t, sentence);
                    if (t.stopped) return;
                    if (event.reason === "tool-calls") {
                        t.calls = calls;
                        t.phase = "routing";
                        next(c, t);
                    } else {
                        t.phase = "done";
                        c.turn = null;
                        t.speech?.end();
                        t.done("brain-done");
                    }
                    return;
                default: fail("brain-event");
                }
            }
            fail("brain-unfinished");
        } catch (error) { failed(c, t, error); }
    }

    // Route a reply's calls one at a time through the router; their results
    // return through outcome() and answer the reply in one tool-results turn.
    function next(c, t) {
        if (t.stopped) return;
        const call = t.calls.find(value => !t.answers.has(value.id));
        if (call === undefined) {
            t.phase = "streaming";
            const after = c.plan.brain.guidance.afterToolResult;
            void respond(c, t, { kind: "tool-results", ...(after === null ? {} : { instructions: after }),
                results: t.calls.map(value => ({ id: value.id, item: t.answers.get(value.id) })) });
            return;
        }
        t.routing = call.id;
        router.route(call, { gen: t.gen, op: t.op });
    }

    function heard(c, t, text) {
        c.heard = { op: t.op, labels: [...t.labels], text };
    }
    function heardItem(value) {
        return Policy.item(value.text === ""
            ? "[interrupted] The user heard none of your last reply."
            : "[interrupted] The user heard only this part of your last reply: \"" + value.text + "\"", value.labels);
    }

    const brain = {
        send(e, done) {
            const c = current(e.gen);
            if (c.brain === null) {
                c.brain = DRIVERS[c.plan.brain.provider.driver].create({ provider: c.plan.brain.provider,
                    model: c.plan.brain.model, net: c.net, recipients: c.recipients, key: c.plan.brain.key });
                c.brain.start({ instructions: c.plan.brain.guidance.instructions, tools: router.offer() });
                c.owner = e.owner;
            } else if (c.owner !== e.owner) fail("brain-owner");
            if (c.turn !== null) fail("brain-busy");
            const t = { gen: e.gen, op: e.op, done, labels: new Set(), spoken: [], speech: null, stopped: false,
                phase: "streaming", calls: [], answers: new Map(), routing: null };
            if (e.text.trim() === "") {
                done("brain-done");
                return;
            }
            c.turn = t;
            c.last = t;
            const items = [];
            if (c.heard !== null) items.push(heardItem(c.heard));
            c.heard = null;
            items.push(Policy.item(e.text, ["speech"]));
            void respond(c, t, { kind: "user", items });
        },
        cancel(e, done) {
            const c = conversation;
            if (c === null || c.gen !== e.gen) {
                (retired !== null && retired.gen === e.gen ? retired.closed : Promise.resolve()).then(() => done());
                return;
            }
            const t = c.turn;
            if (t === null || t.op !== e.target) { done(); return; }
            c.turn = null;
            stop(t);
            heard(c, t, "");
            const routing = t.phase === "routing";
            void c.brain.cancel().then(() => {
                // Calls the user interrupted keep a truthful answer, so the
                // next request is valid. A late outcome is dropped.
                if (routing && c.brain !== null) c.brain.record({ kind: "tool-results", results: t.calls.map(call => ({
                    id: call.id, item: t.answers.get(call.id)
                        ?? Policy.item("{\"kind\":\"interrupted\",\"outcome\":\"unknown\"}", ["desktop"]) })) });
                done();
            });
        },
        close(e) {
            const c = conversation;
            if (c === null || c.owner !== e.target || c.brain === null) return;
            c.brain.close();
            c.brain = null;
            c.owner = null;
        },
        outcome(value) {
            const c = conversation;
            const t = c?.turn;
            if (!t || c.gen !== value.gen || t.op !== value.op || t.phase !== "routing"
                    || value.results.length !== 1 || value.results[0].id !== t.routing) return;
            t.answers.set(t.routing, value.results[0].item);
            t.routing = null;
            next(c, t);
        }
    };

    // Audio's flush report carries the heard prefix of this turn's speech.
    // Natural completion drained every sentence, so it changes nothing.
    function playback(port) {
        return {
            start: port.start,
            flush(e, done) {
                return port.flush(e, report => {
                    const c = conversation;
                    const t = c?.last;
                    if (t && (report === null || report.source === t.op))
                        heard(c, t, report === null ? "" : report.heardText);
                    done(report);
                });
            }
        };
    }

    return Object.freeze({
        /** Select from snapshot settings; the daemon raises its gate only on ready. */
        configure(settings) {
            plan = select(settings, accounts);
            return plan.kind === "ready" ? { kind: "ready" } : plan;
        },
        observe(s) { if (conversation !== null && s.gen !== conversation.gen) end(); },
        captureSink(e) {
            const c = current(e.gen);
            const t = transcription(c, e);
            if (c.collection !== null && c.collection.transcription === null
                    && live(c.gen, c.collection.op, "turn", ["collecting"])) {
                t.collection = c.collection;
                c.collection.transcription = t;
            } else c.unbound = t;
            return t.sink;
        },
        collect(e, done) {
            const c = current(e.gen);
            c.collection = { op: e.op, done, transcription: c.unbound };
            if (c.unbound !== null) c.unbound.collection = c.collection;
            c.unbound = null;
        },
        playbackSource(op) {
            const t = conversation?.last;
            if (!t || t.op !== op || t.speech === null || t.speech.handed) return null;
            t.speech.handed = true;
            return t.speech.readable;
        },
        playback, brain,
        close() {
            end();
            closed = true;
        }
    });
}

module.exports = { create };
