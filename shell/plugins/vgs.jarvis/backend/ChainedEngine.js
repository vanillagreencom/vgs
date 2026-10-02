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
const CodexHarness = require("./CodexHarness.js");
const AcpHarness = require("./AcpHarness.js");

// Speech adapter rows in selection order. A row is {select({settings,
// accounts})} answering {kind:"ready", recipients, open({net, recipients})}
// or {kind:"unconfigured", cause}. The local and ElevenLabs rows add theirs.
const SPEECH = Object.freeze({});
const DRIVERS = Object.freeze({ "openai-chat": OpenAIChat, "anthropic-messages": AnthropicMessages,
    "codex-app-server": CodexHarness, acp: AcpHarness });
// The hello carries no language setting; empty selects English.
const LANGUAGE = "";
// Object-mode chunks queued toward Audio, below its playback allowance.
const SPEECH_CHUNKS = 16;
// Released sentence text waiting for synthesis, in UTF-16 code units. One
// response is bounded at its source; this bounds the text Speakable made.
const SENTENCE_TEXT = 8 * 1024 * 1024;
// Capture bytes held for transcription before Audio sees backpressure.
const CAPTURE_BYTES = 16 * 1024;
// Release records name the transfer leaving the machine.
const RELEASE_EFFECT = "external";

function fail(code) { throw new Error("jarvis: engine=" + code); }
function unconfigured(cause, detail) { return detail === undefined ? { kind: "unconfigured", cause } : { kind: "unconfigured", cause, detail }; }
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
 * declaration's Verify probe model, the provider table and the key reference.
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
    } catch (error) {
        // Only the account and key readers' keyed failures are a cause here.
        if (!/^jarvis-(?:accounts|keys): /.test(error?.message ?? "")) throw error;
        return unconfigured("brain=accounts-unreadable", error.message);
    }
    if (account === null) return unconfigured("brain=account-unavailable");
    // A subscription's program chooses its own default model.
    if (account.model === "" && account.source.kind !== "cli") return unconfigured("brain=model-required");
    const provider = Providers.select(account.provider);
    if (!Object.hasOwn(DRIVERS, provider.driver)) fail("driver");
    const target = Net.endpoint(provider.base);
    return { kind: "ready", speech, brain: { provider, model: account.model, account: account.source,
        key: account.source.kind === "keyring" ? { secrets: judge.secrets, reference: account.source.reference } : null,
        recipient: { kind: "network", provider: provider.id, account: account.id, origin: target.origin },
        guidance: Guidance.compose("chained", target.loopback ? "local" : "text", LANGUAGE) } };
}

/**
 * create({session, state, audit, router, accounts, policy, fault, harness})
 * owns the daemon's chained conversations. session is the Session judge and state
 * returns its current record; audit is the daemon's writer; router supplies
 * offer, route, observe and interrupted; accounts returns an Accounts judge;
 * policy returns {profile, cloudVision}; fault reports a speech failure that
 * no capture or turn remains to carry. harness is {bridge, gate, env, runtime}
 * for a harness brain: the tool bridge, the HarnessGate, the environment its
 * program is started from and a function answering the runtime directory.
 */
function create({ session, state, audit, router, accounts, policy, fault, harness = null }) {
    let plan = unconfigured("engine=starting");
    let conversation = null;
    let retired = null;
    let closed = false;

    function releaseEvent(c, identity, labels, decision, outcome) {
        return { kind: "release", gen: identity.gen, op: identity.op, tool: "release",
            args: { labels, recipients: c.recipients }, effect: RELEASE_EFFECT, decision, confirmed: "none", outcome };
    }
    // An asked or withheld item travels as its marker; its decision is kept.
    function record(c, identity, labels, decision) {
        if (audit.record(releaseEvent(c, identity, labels, decision, "completed")).kind !== "recorded") fail("audit-write");
    }
    // Every transfer is judged against the whole set, then audited first.
    function transfer(c, identity, item, start) {
        if (Policy.release(item, c.recipients, c.grants).kind !== "send") fail("release-" + item.labels.join("-"));
        const result = audit.before(releaseEvent(c, identity, item.labels, "send", "pending"), start);
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
        // late holds at most one call: the router runs one action at a time.
        return { gen, plan, recipients, net, speech, brain: null, owner: null, grants: [], heard: null,
            late: new Map(), results: [], turn: null, last: null, collection: null, unbound: null };
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
        for (const utterance of [c.collection?.utterance, c.unbound])
            if (utterance) utterance.abort();
        const brain = c.brain;
        c.brain = null;
        const quiet = brain === null ? Promise.resolve() : brain.cancel();
        brain?.close();
        c.speech.close();
        c.net.close();
        retired = { gen: c.gen, closed: quiet };
    }
    function collecting(c, collection) {
        return collection !== null && session.live(state(), { gen: c.gen, op: collection.op }, "turn", ["collecting"]);
    }

    // Speech to text. The capture sink exists while Audio holds the
    // recorder; one utterance yields partials and one final.
    function transcription(c, e) {
        let held = null;
        let finished = false;
        let released = false;
        let output = null;
        const wake = signal();
        // running: transcribing; concluded: final delivered or failed;
        // aborted: abandoned by the conversation or by its replacement.
        const utterance = { state: "running", collection: null, sink: null, abort() {
            if (utterance.state !== "running") return;
            utterance.state = "aborted";
            held = null;
            wake.notify();
            void output?.return?.();
        } };
        const sink = new Writable({
            highWaterMark: CAPTURE_BYTES,
            // Frames after the adapter stopped reading have no consumer.
            write(chunk, encoding, done) {
                if (released || utterance.state !== "running") { done(); return; }
                held = { chunk, done };
                wake.notify();
            },
            final(done) { finished = true; wake.notify(); done(); },
            // Audio's teardown ends the utterance. A conversation that ended
            // with it, as by mute or stop, aborts the utterance in end().
            destroy(error, done) {
                finished = true;
                held = null;
                wake.notify();
                done(error);
            }
        });
        utterance.sink = sink;
        // Each frame reaches the adapter as a speech-labelled item, so a
        // network adapter's own send re-judges what it carries.
        const frames = { [Symbol.asyncIterator]() { return { async next() {
            for (;;) {
                if (utterance.state !== "running") return { value: undefined, done: true };
                if (held !== null) {
                    const { chunk, done } = held;
                    held = null;
                    done();
                    return { value: Policy.item(chunk, ["speech"]), done: false };
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
                transfer(c, e, Policy.item("", ["speech"]), () => {
                    output = c.speech.transcribe(frames)[Symbol.asyncIterator]();
                });
                for (;;) {
                    const step = await output.next();
                    if (utterance.state !== "running") return;
                    if (step.done) fail("transcript-unfinished");
                    const event = step.value;
                    if (event === null || typeof event !== "object" || typeof event.text !== "string") fail("transcript");
                    if (event.kind === "partial") {
                        if (!Number.isSafeInteger(event.rev) || event.rev <= rev) fail("transcript-revision");
                        rev = event.rev;
                        utterance.collection?.done("partial", event.text);
                    } else if (event.kind === "final") {
                        utterance.state = "concluded";
                        utterance.collection?.done("final", event.text);
                        void output.return?.();
                        return;
                    } else fail("transcript");
                }
            } catch (error) {
                if (utterance.state !== "running") return;
                utterance.state = "concluded";
                // An open capture carries the failure; after it closed, the
                // collection's turn does; unbound, only the service hears it.
                if (!sink.destroyed) sink.destroy(error);
                else if (collecting(c, utterance.collection)) utterance.collection.failed(keyed(error));
                else fault("speech-transcribe: " + keyed(error));
            }
        }
        void run();
        return utterance;
    }

    // Text to speech for one brain turn: one Readable for Audio, fed by the
    // adapter from released sentences. Synthesis waits on Audio; the brain
    // is read to its end, so its deadline never waits on speech.
    function speech(c) {
        const sentences = [];
        let queued = 0;
        const input = signal(), wanted = signal();
        let ended = false;
        const readable = new Readable({ objectMode: true, highWaterMark: SPEECH_CHUNKS,
            read() { wanted.notify(); } });
        // Audio reports a failed source as a failed playback, including one
        // destroyed before Audio attached its own listener.
        readable.on("error", () => {});
        readable.once("close", () => { ended = true; input.notify(); wanted.notify(); });
        const sentenceInput = { [Symbol.asyncIterator]() { return { async next() {
            for (;;) {
                if (sentences.length !== 0) {
                    const value = sentences.shift();
                    queued -= value.content.length;
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
            queue(item) {
                if (queued + item.content.length > SENTENCE_TEXT) fail("speech-queue");
                queued += item.content.length;
                sentences.push(item);
                input.notify();
            },
            end() { ended = true; input.notify(); }
        };
    }

    function say(c, turn, sentence) {
        if (turn.stopped) return;
        const item = Policy.item(sentence, [...turn.labels]);
        transfer(c, turn, item, () => {
            if (turn.speech === null) {
                turn.speech = speech(c);
                turn.done("play", { interruptible: true });
            }
            turn.speech.queue(item);
        });
    }

    function stop(turn) {
        turn.stopped = true;
        turn.speech?.end();
    }
    function failed(c, turn, error) {
        if (turn.stopped) return;
        stop(turn);
        if (c.turn === turn) c.turn = null;
        const reason = keyed(error);
        // The history bound ends the conversation cleanly; any other failure
        // is a fault.
        turn.done(reason === "brain=context-limit" ? "brain-ended" : "brain-failed", { reason });
    }

    async function respond(c, turn, request) {
        try {
            const reply = c.brain.send(request, c.grants);
            if (reply.release.needed.length !== 0) record(c, turn, reply.release.needed, "ask");
            if (reply.release.withheld.length !== 0) record(c, turn, reply.release.withheld, "withhold");
            for (const label of reply.release.labels) turn.labels.add(label);
            // History can carry an earlier turn's untrusted content.
            router.observe(turn, reply.release.labels);
            const events = reply.events[Symbol.asyncIterator]();
            const text = Speakable.create(LANGUAGE);
            const calls = [];
            // A request with no released content refuses before it is sent.
            let step = await (reply.release.labels.length === 0 ? events.next()
                : transfer(c, turn, Policy.item("", reply.release.labels), () => events.next()));
            for (; !step.done; step = await events.next()) {
                if (turn.stopped) return;
                const event = step.value;
                switch (event.kind) {
                case "text":
                    for (const sentence of text.push(event.text)) say(c, turn, sentence);
                    break;
                case "tool-call": calls.push(event); break;
                case "done":
                    // History holds the calls once done is read: an interrupt
                    // from here on must answer them.
                    if (event.reason === "tool-calls") {
                        turn.calls = calls;
                        turn.phase = "routing";
                    }
                    for (const sentence of text.finish()) say(c, turn, sentence);
                    if (turn.stopped) return;
                    if (event.reason === "tool-calls") next(c, turn);
                    else {
                        turn.phase = "done";
                        c.turn = null;
                        turn.speech?.end();
                        turn.done("brain-done");
                    }
                    return;
                default: fail("brain-event");
                }
            }
            fail("brain-unfinished");
        } catch (error) { failed(c, turn, error); }
    }

    // Route a reply's calls one at a time through the router; their results
    // return through outcome() and answer the reply in one tool-results turn.
    function next(c, turn) {
        if (turn.stopped) return;
        const call = turn.calls.find(value => !turn.answers.has(value.id));
        if (call === undefined) {
            turn.phase = "streaming";
            const after = c.plan.brain.guidance.afterToolResult;
            void respond(c, turn, { kind: "tool-results", ...(after === null ? {} : { instructions: after }),
                results: turn.calls.map(value => ({ id: value.id, ...turn.answers.get(value.id) })) });
            return;
        }
        turn.routing = call;
        router.route(call, { gen: turn.gen, op: turn.op });
    }

    function heard(c, turn, text) {
        c.heard = { labels: [...turn.labels], text };
    }
    function heardItem(value) {
        return Policy.item(value.text === ""
            ? "[interrupted] The user heard none of your last reply."
            : "[interrupted] The user heard only this part of your last reply: \"" + value.text + "\"", value.labels);
    }
    // An interrupted call's real outcome reaches the next user turn, labelled
    // as its result is.
    function lateItem(call, outcome, item) {
        return Policy.summary("[late result] Your interrupted call " + call.tool + " ended " + outcome + ": "
            + item.content, [item]);
    }

    const brain = {
        send(e, done) {
            const c = current(e.gen);
            if (c.brain === null) {
                c.brain = DRIVERS[c.plan.brain.provider.driver].create({ provider: c.plan.brain.provider,
                    model: c.plan.brain.model, net: c.net, recipients: c.recipients, key: c.plan.brain.key,
                    account: c.plan.brain.account, gen: c.gen, harness });
                c.brain.start({ instructions: c.plan.brain.guidance.instructions, tools: router.offer() });
                c.owner = e.owner;
            } else if (c.owner !== e.owner) fail("brain-owner");
            if (c.turn !== null) fail("brain-busy");
            const turn = { gen: e.gen, op: e.op, done, labels: new Set(), speech: null, stopped: false,
                phase: "streaming", calls: [], answers: new Map(), routing: null };
            if (e.text.trim() === "") {
                done("brain-done");
                return;
            }
            c.turn = turn;
            c.last = turn;
            const items = [];
            if (c.heard !== null) items.push(heardItem(c.heard));
            c.heard = null;
            items.push(...c.results);
            c.results = [];
            items.push(Policy.item(e.text, ["speech"]));
            void respond(c, turn, { kind: "user", items });
        },
        cancel(e, done) {
            const c = conversation;
            if (c === null || c.gen !== e.gen) {
                (retired !== null && retired.gen === e.gen ? retired.closed : Promise.resolve()).then(() => done());
                return;
            }
            const turn = c.turn;
            if (turn === null || turn.op !== e.target) { done(); return; }
            c.turn = null;
            stop(turn);
            heard(c, turn, "");
            const routing = turn.phase === "routing";
            void c.brain.cancel().then(() => {
                // Every call in history gets an answer, so the next request is
                // valid. A running call's real outcome follows on a later turn.
                if (routing && c.brain !== null) c.brain.record({ kind: "tool-results", results: turn.calls.map(call => {
                    if (turn.answers.has(call.id)) return { id: call.id, ...turn.answers.get(call.id) };
                    if (turn.routing === call) {
                        c.late.set(call.id, { call, op: turn.op });
                        return router.interrupted(call, "running");
                    }
                    return router.interrupted(call, "not-started");
                }) });
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
            if (c === null || c.gen !== value.gen || value.results.length !== 1) return;
            const { id, item, image } = value.results[0];
            const turn = c.turn;
            if (turn !== null && turn.op === value.op && turn.phase === "routing" && turn.routing?.id === id) {
                // A result's image stays with its text for the tool-results turn.
                turn.answers.set(id, image === undefined ? { item } : { item, image });
                turn.routing = null;
                next(c, turn);
                return;
            }
            const late = c.late.get(id);
            if (late === undefined || late.op !== value.op) return;
            c.late.delete(id);
            c.results.push(lateItem(late.call, value.outcome, item));
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
                    const turn = c?.last;
                    if (turn && (report === null || report.source === turn.op))
                        heard(c, turn, report === null ? "" : report.heardText);
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
        /** Whether the conversation's brain, or the next one's, takes images. */
        images() {
            const current = conversation !== null ? conversation.plan : plan;
            return current.kind === "ready" && current.brain.provider.images;
        },
        // A live collection adopts the new utterance; otherwise it waits
        // unbound, replacing and abandoning any earlier unbound one.
        captureSink(e) {
            const c = current(e.gen);
            const utterance = transcription(c, e);
            const collection = c.collection;
            if (collecting(c, collection) && collection.utterance === null) {
                utterance.collection = collection;
                collection.utterance = utterance;
            } else {
                c.unbound?.abort();
                c.unbound = utterance;
            }
            return utterance.sink;
        },
        // Only a running unbound utterance answers a new collection; one that
        // already concluded spoke before the collection existed.
        collect(e, done, failed) {
            const c = current(e.gen);
            const adopted = c.unbound !== null && c.unbound.state === "running" ? c.unbound : null;
            if (adopted === null) c.unbound?.abort();
            c.collection = { op: e.op, done, failed, utterance: adopted };
            if (adopted !== null) adopted.collection = c.collection;
            c.unbound = null;
        },
        playbackSource(op) {
            const turn = conversation?.last;
            if (!turn || turn.op !== op || turn.speech === null || turn.speech.handed) return null;
            turn.speech.handed = true;
            return turn.speech.readable;
        },
        playback, brain,
        close() {
            end();
            closed = true;
        }
    });
}

module.exports = { create };
