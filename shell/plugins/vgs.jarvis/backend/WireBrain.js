// Conversation, labelled history and request lifetime shared by the two wire
// brains. Protocol drivers own only their provider's encoding and event judge.
// Contract: docs/architecture/jarvis-brain.md.
"use strict";
const Policy = require("./Policy.js");
const Providers = require("./Providers.js");
const Tools = require("./Tools.js");
const Net = require("./net.js");
const Sse = require("./Sse.js");

const REQUEST_BYTES = 20 * 1024 * 1024;
// Bound one wire response and the reply its conversation keeps in history.
const SSE_LIMITS = Object.freeze({ line: 1024 * 1024, event: 1024 * 1024, total: 8 * 1024 * 1024 });
const TOOLS = 64;
const IMAGE_TYPES = ["image/png", "image/jpeg"];
function fail(code) { throw new Error("jarvis: brain=" + code); }
function plain(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function textItem(item) {
    if (!item || typeof item.content !== "string") fail("item-text");
    return item;
}

/** Own one wire conversation. The protocol object is supplied only by drivers. */
function create({ provider, model, net, recipients, key }, protocol) {
    Providers.assertRow(provider);
    Policy.assertRecipients(recipients);
    if (provider.driver !== protocol.driver) fail("driver");
    if (key === null && provider.key === "required") fail("no-key");
    if (key !== null) Net.assertKeyTarget(provider.base, key.reference.origin);
    let secret = null;
    let context = null;
    let history = [];
    let active = null;
    let closed = false;

    function usable() {
        if (closed) fail("closed");
        if (active !== null) fail("busy");
    }
    function start(value) {
        usable();
        if (typeof value.instructions !== "string") fail("instructions");
        if (value.tools.length > TOOLS) fail("tools");
        const names = Tools.wireNames(value.tools.map(tool => tool.id));
        if (names === null) fail("tool-name");
        const tools = [...names.keys()].map((name, index) => protocol.tool(name, value.tools[index]));
        context = { instructions: value.instructions, tools, names };
        history = [];
    }
    function pending() {
        const last = history.at(-1);
        return last !== undefined && last.role === "assistant" ? last.calls : [];
    }
    function entryOf(turn) {
        switch (turn?.kind) {
        case "user": {
            if (pending().length !== 0) fail("tool-results-pending");
            const images = turn.images ?? [];
            if (!Array.isArray(turn.items) || !Array.isArray(images) || turn.items.length + images.length === 0)
                fail("turn");
            if (images.length !== 0 && !provider.images) fail("images-unsupported");
            for (const image of images) {
                if (!plain(image) || !IMAGE_TYPES.includes(image.type)) fail("image-type");
                if (!image.item || !(image.item.content instanceof Uint8Array)) fail("image-bytes");
            }
            return { role: "user", items: turn.items.map(textItem),
                images: images.map(image => ({ type: image.type, item: image.item })) };
        }
        case "tool-results": {
            const calls = pending();
            const results = turn.results;
            if (calls.length === 0 || !Array.isArray(results) || results.length !== calls.length) fail("tool-results");
            const byId = new Map(results.map(result => [result?.id, result?.item]));
            if (byId.size !== calls.length || !calls.every(call => byId.has(call.id))) fail("tool-results");
            return { role: "tool-results", results: calls.map(call => ({ id: call.id, item: textItem(byId.get(call.id)) })) };
        }
        default: return fail("turn");
        }
    }
    function render(entries, grants) {
        const sent = [];
        const withheld = new Set();
        const needed = new Set();
        function released(item) {
            const decision = Policy.release(item, recipients, grants);
            switch (decision.kind) {
            case "send": sent.push(item); break;
            case "ask": for (const label of decision.needed) needed.add(label); break;
            case "withhold": for (const label of decision.labels) withheld.add(label); break;
            default: throw new Error("jarvis: brain=release-kind");
            }
            return decision;
        }
        const messages = [];
        for (const entry of entries) {
            switch (entry.role) {
            case "user":
                messages.push(protocol.user(entry.items.map(item => released(item).content),
                    entry.images.map(image => ({ type: image.type, decision: released(image.item) }))));
                break;
            case "assistant":
                if (released(entry.item).kind !== "send") fail("history-release");
                messages.push(protocol.assistant(entry));
                break;
            case "tool-results":
                messages.push(...protocol.results(entry.results.map(result =>
                    ({ id: result.id, content: released(result.item).content }))));
                break;
            default: throw new Error("jarvis: brain=history-role");
            }
        }
        const labels = [...new Set(sent.flatMap(item => item.labels))];
        const body = JSON.stringify({ ...protocol.request(model, context.instructions, messages),
            ...(context.tools.length === 0 ? {} : { tools: context.tools }), ...provider.noStore });
        if (Buffer.byteLength(body) > REQUEST_BYTES) fail("request-limit");
        return { item: labels.length === 0 ? null : Policy.item(body, labels), sent,
            release: Object.freeze({ withheld: Object.freeze([...withheld]), needed: Object.freeze([...needed]) }) };
    }

    function send(turn, grants = []) {
        usable();
        if (context === null) fail("not-started");
        const entry = entryOf(turn);
        const request = render([...history, entry], grants);
        const controller = new AbortController();
        const queue = [];
        let state = { kind: "unstarted" };
        let commit = null;
        let wake = () => {};
        let ended;
        const finished = new Promise(resolve => { ended = resolve; });
        function release() {
            if (active === current) active = null;
        }
        const current = { cancel() {
            controller.abort();
            switch (state.kind) {
            case "unstarted":
                state = { kind: "cancelled" };
                ended();
                break;
            case "streaming": case "complete": case "failed":
                state = { kind: "cancelled" };
                wake();
                break;
            case "cancelled": case "ended": break;
            default: throw new Error("jarvis: brain=turn-state");
            }
            return finished.then(release);
        } };

        async function stream() {
            let answer = null;
            try {
                if (request.item === null) fail("release-empty");
                const options = { url: provider.base + protocol.path, signal: controller.signal,
                    headers: { "content-type": "application/json", accept: "text/event-stream", ...protocol.headers } };
                if (key !== null) {
                    if (secret === null) secret = key.secrets.lookup(key.reference);
                    options.key = { origin: key.reference.origin, ...protocol.auth, value: secret.toString("utf8") };
                }
                answer = await net.request(request.item, options, grants);
                if (answer.kind !== "response") fail("release-request");
                const response = answer.response;
                if (response.status !== 200) {
                    // Error bodies can echo content or credentials.
                    await response.body?.cancel();
                    fail((protocol.status[response.status] ?? "http") + " status=" + response.status);
                }
                if (!/^text\/event-stream\s*(;|$)/i.test(response.headers.get("content-type") ?? "")) fail("content-type");
                const parser = Sse.reader(SSE_LIMITS);
                const consume = protocol.reader(context.names);
                const body = response.body.getReader();
                for (;;) {
                    let read;
                    try { read = await body.read(); } catch { fail(controller.signal.aborted ? "cancelled" : "stream-failed"); }
                    if (read.done) fail("stream-truncated");
                    for (const event of parser.push(read.value)) {
                        const result = consume(event);
                        switch (result.kind) {
                        case "continue": break;
                        case "text":
                            queue.push({ kind: "text", text: result.text });
                            wake();
                            break;
                        case "complete":
                            commit = () => history.push(entry, { role: "assistant",
                                item: Policy.summary(result.text, request.sent), ...result });
                            for (const call of result.calls)
                                queue.push({ kind: "tool-call", id: call.id, tool: call.tool, arguments: call.parsed });
                            queue.push({ kind: "done", reason: result.reason });
                            if (state.kind === "streaming") state = { kind: "complete" };
                            wake();
                            return;
                        default: throw new Error("jarvis: brain=reader-kind");
                        }
                    }
                }
            } catch (error) {
                if (state.kind === "streaming")
                    state = controller.signal.aborted ? { kind: "cancelled" } : { kind: "failed", error };
                wake();
            } finally {
                if (answer !== null && answer.kind === "response") answer.close();
                ended();
            }
        }
        const events = {
            [Symbol.asyncIterator]() { return this; },
            async next() {
                if (state.kind === "unstarted") {
                    state = { kind: "streaming" };
                    stream();
                }
                for (;;) {
                    switch (state.kind) {
                    case "cancelled":
                        state = { kind: "ended" };
                        release();
                        throw new Error("jarvis: brain=cancelled");
                    case "ended": return { value: undefined, done: true };
                    case "streaming": case "complete": case "failed":
                        if (queue.length !== 0) {
                            const value = queue.shift();
                            if (value.kind === "done") {
                                commit();
                                state = { kind: "ended" };
                                release();
                            }
                            return { value, done: false };
                        }
                        if (state.kind === "failed") {
                            const error = state.error;
                            state = { kind: "ended" };
                            release();
                            throw error;
                        }
                        if (state.kind === "complete") throw new Error("jarvis: brain=turn-state");
                        break;
                    default: throw new Error("jarvis: brain=turn-state");
                    }
                    await new Promise(resolve => { wake = resolve; });
                }
            },
            async return() {
                await current.cancel();
                return { value: undefined, done: true };
            }
        };
        active = current;
        return Object.freeze({ release: request.release, events });
    }
    function cancel() { return active === null ? Promise.resolve() : active.cancel(); }
    function close() {
        if (closed) return;
        closed = true;
        if (active !== null) active.cancel();
        if (secret !== null) secret.fill(0);
        secret = null;
        context = null;
        history = [];
    }
    return Object.freeze({ start, send, cancel, close });
}
module.exports = { create };
