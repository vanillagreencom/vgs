// The OpenAI-compatible Chat Completions driver: one conversation's wire brain
// over the net.js door. The session owns the net owner, recipient set and
// grants; this driver owns the conversation's provider-format history.
// Wire contract: docs/architecture/jarvis-brain.md.
"use strict";
const Policy = require("./Policy.js");
const Providers = require("./Providers.js");
const Net = require("./net.js");
const Sse = require("./Sse.js");

// The pinned OpenAPI document's ApiKeyAuth scheme is HTTP bearer.
const AUTH = Object.freeze({ header: "authorization", prefix: "Bearer " });
// A line holds one chunk; local servers send a whole tool call in one chunk.
// The total bounds one response, and with it the text kept in history.
const SSE_LIMITS = Object.freeze({ line: 1024 * 1024, event: 1024 * 1024, total: 8 * 1024 * 1024 });
// The lowest request ceiling a table row documents: Groq, with an image.
const REQUEST_BYTES = 20 * 1024 * 1024;
const TOOLS = 64;
const TOOL_CALLS = 16;
// The screen executor's grim output formats; every image row accepts both.
const IMAGE_TYPES = ["image/png", "image/jpeg"];
// FunctionObject.name in the pinned OpenAPI document.
const NAME = /^[A-Za-z0-9_-]{1,64}$/;
// The error statuses the pinned OpenAPI document lists for this operation.
const STATUS = Object.freeze({ 400: "request-rejected", 401: "unauthorized", 403: "forbidden",
    404: "not-found", 429: "rate-limited", 500: "provider-error", 503: "unavailable" });

function fail(code) { throw new Error("jarvis: brain=" + code); }

function plain(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function optionalString(value) {
    return value === undefined || typeof value === "string";
}

// The one narrowing door for a streamed data frame. Fields this driver does
// not read, such as usage or a server's reasoning text, pass unread.
function chunkOf(data) {
    let value;
    try { value = JSON.parse(data); } catch { fail("chunk-json"); }
    if (!plain(value)) fail("chunk-shape");
    // The operation's documented mid-stream failure frame. Its provider text
    // stays unread, like an HTTP error body.
    if (Object.hasOwn(value, "error")) fail("stream-error");
    if (!Array.isArray(value.choices) || value.choices.length > 1) fail("chunk-shape");
    if (value.choices.length === 0) return null;
    const choice = value.choices[0];
    if (!plain(choice) || choice.index !== 0 || !plain(choice.delta)) fail("chunk-shape");
    const { content, refusal, tool_calls: fragments } = choice.delta;
    const finish = choice.finish_reason;
    if ((content !== null && !optionalString(content)) || (refusal !== null && !optionalString(refusal))
            || (finish !== null && !optionalString(finish)))
        fail("chunk-shape");
    if (fragments !== undefined && (!Array.isArray(fragments) || !fragments.every(fragment => plain(fragment)
            && Number.isSafeInteger(fragment.index) && fragment.index >= 0 && optionalString(fragment.id)
            && (fragment.type === undefined || fragment.type === "function")
            && (fragment.function === undefined || (plain(fragment.function)
                && optionalString(fragment.function.name) && optionalString(fragment.function.arguments))))))
        fail("chunk-shape");
    if (typeof refusal === "string" && refusal !== "") fail("refusal");
    return { text: content ?? "", fragments: fragments ?? [], finish: finish ?? null };
}

// Fragments arrive by index. The first fragment of a call names it; later
// fragments only extend its arguments. A gap, a nameless start or arguments
// that do not parse mean a lost chunk, so the turn fails without a call.
function assembler(names) {
    const calls = [];
    function add(fragment) {
        const name = fragment.function?.name;
        const piece = fragment.function?.arguments ?? "";
        if (fragment.index > calls.length) fail("tool-call-index");
        if (fragment.index === calls.length) {
            if (calls.length === TOOL_CALLS) fail("tool-call-limit");
            if (typeof fragment.id !== "string" || fragment.id === "" || typeof name !== "string" || name === "")
                fail("tool-call-start");
            calls.push({ id: fragment.id, name, arguments: piece });
            return;
        }
        const call = calls[fragment.index];
        if ((fragment.id !== undefined && fragment.id !== call.id) || (name !== undefined && name !== call.name))
            fail("tool-call-conflict");
        call.arguments += piece;
    }
    function complete() {
        if (new Set(calls.map(call => call.id)).size !== calls.length) fail("tool-call-id");
        return calls.map(call => {
            if (!names.has(call.name)) fail("tool-call-name");
            let parsed;
            try { parsed = JSON.parse(call.arguments); } catch { fail("tool-call-arguments"); }
            if (!plain(parsed)) fail("tool-call-arguments");
            return Object.freeze({ ...call, tool: names.get(call.name), parsed });
        });
    }
    return { add, complete, get count() { return calls.length; } };
}

// The finish_reason values of the pinned stream chunk.
function outcome(finish, count) {
    switch (finish) {
    // Gemini's compatible endpoint ends a tool-call turn with stop. Assembly
    // has already refused a lost chunk, so the calls decide the ending.
    case "stop": return count === 0 ? "stop" : "tool-calls";
    case "tool_calls":
        if (count === 0) fail("finish reason=tool-calls-without-call");
        return "tool-calls";
    case "length": return fail("finish reason=length");
    case "content_filter": return fail("finish reason=content-filter");
    case "function_call": return fail("finish reason=function-call");
    case null: return fail("finish-missing");
    default: return fail("chunk-shape");
    }
}

function textItem(item) {
    if (!item || typeof item.content !== "string") fail("item-text");
    return item;
}

/**
 * create({provider, model, net, recipients, key}) returns one conversation's
 * brain: start, send, cancel and close. provider is a Providers.select row,
 * net the session's net.create owner for recipients, key null or
 * {secrets, reference}: a Secrets store and the account's key reference.
 * Its secret is looked up at the first request, kept for the conversation
 * and zeroed by close. The JavaScript copies the request headers need cannot
 * be zeroed; they are unreachable once each request ends.
 */
function create({ provider, model, net, recipients, key }) {
    Providers.assertRow(provider);
    Policy.assertRecipients(recipients);
    if (key === null && provider.key === "required") fail("no-key");
    // net judges the key at every request; refusing here keeps a key that
    // could never be sent out of the keyring and out of memory.
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

    /**
     * start({instructions, tools}) begins a new history. instructions is the
     * shipped guidance text; tools are {id, description, parameters} with a
     * JSON Schema object. A tool id's dots become underscores on the wire,
     * which allows only FunctionObject.name's characters.
     */
    function start(value) {
        usable();
        if (typeof value.instructions !== "string") fail("instructions");
        if (value.tools.length > TOOLS) fail("tools");
        const names = new Map();
        const tools = value.tools.map(tool => {
            const name = tool.id.replaceAll(".", "_");
            if (!NAME.test(name) || names.has(name)) fail("tool-name");
            names.set(name, tool.id);
            return { type: "function", function: { name, description: tool.description, parameters: structuredClone(tool.parameters) } };
        });
        context = { instructions: value.instructions, tools, names };
        history = [];
    }

    function pending() {
        const last = history.at(-1);
        return last !== undefined && last.role === "assistant" ? last.calls : [];
    }

    // A turn is {kind:"user", items, images?} with Policy items, or
    // {kind:"tool-results", results:[{id, item}]} answering every pending call.
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

    // Every history item passes release on every request. Asked and withheld
    // items travel as their markers; the request item carries only the labels
    // of content it includes.
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
        const messages = [{ role: "system", content: context.instructions }];
        for (const entry of entries) {
            switch (entry.role) {
            case "user": {
                const texts = entry.items.map(item => released(item).content);
                if (entry.images.length === 0) { messages.push({ role: "user", content: texts.join("\n\n") }); break; }
                messages.push({ role: "user", content: [
                    ...texts.map(text => ({ type: "text", text })),
                    ...entry.images.map(image => {
                        const decision = released(image.item);
                        return decision.kind === "send"
                            ? { type: "image_url", image_url: { url: "data:" + image.type + ";base64," + decision.content.toString("base64") } }
                            : { type: "text", text: decision.content };
                    })] });
                break;
            }
            case "assistant": {
                // A reply carries the labels of what its request sent. Grants
                // only grow within a conversation, so a reply stays sendable.
                if (released(entry.item).kind !== "send") fail("history-release");
                const message = { role: "assistant", content: entry.text === "" ? null : entry.text };
                if (entry.calls.length !== 0) message.tool_calls = entry.calls.map(call =>
                    ({ id: call.id, type: "function", function: { name: call.name, arguments: call.arguments } }));
                messages.push(message);
                break;
            }
            case "tool-results":
                for (const result of entry.results)
                    messages.push({ role: "tool", tool_call_id: result.id, content: released(result.item).content });
                break;
            default: throw new Error("jarvis: brain=history-role");
            }
        }
        // With nothing released the request would carry only markers. Its
        // release report still reaches the caller; iterating refuses.
        const labels = [...new Set(sent.flatMap(item => item.labels))];
        const body = JSON.stringify({ model, messages, stream: true,
            ...(context.tools.length === 0 ? {} : { tools: context.tools }), ...provider.noStore });
        if (Buffer.byteLength(body) > REQUEST_BYTES) fail("request-limit");
        return { item: labels.length === 0 ? null : Policy.item(body, labels), sent,
            release: Object.freeze({ withheld: Object.freeze([...withheld]), needed: Object.freeze([...needed]) }) };
    }

    /**
     * send(turn, grants?) renders the request at once and returns
     * {release: {withheld, needed}, events}. Nothing leaves until events is
     * iterated, so a caller may ask for a grant first and return() instead.
     * events yields {kind:"text", text} as it streams, then each assembled
     * {kind:"tool-call", id, tool, arguments} and one {kind:"done", reason}.
     * Every other ending throws a keyed error. The turn stays live until its
     * caller reads done or the error, or cancels it. The turn and its reply
     * enter history when the caller reads done.
     */
    function send(turn, grants = []) {
        usable();
        if (context === null) fail("not-started");
        const entry = entryOf(turn);
        const request = render([...history, entry], grants);
        const controller = new AbortController();
        const queue = [];
        // unstarted, streaming, complete (done is queued), failed (the error
        // is unread), cancelled (the next read throws), ended.
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
                // The next read throws, so nothing queued before the
                // acknowledgement reaches the caller.
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
                const options = { url: provider.base + "/chat/completions", signal: controller.signal,
                    headers: { "content-type": "application/json", accept: "text/event-stream" } };
                if (key !== null) {
                    if (secret === null) secret = key.secrets.lookup(key.reference);
                    options.key = { origin: key.reference.origin, ...AUTH, value: secret.toString("utf8") };
                }
                answer = await net.request(request.item, options, grants);
                if (answer.kind !== "response") fail("release-request");
                const response = answer.response;
                if (response.status !== 200) {
                    // Provider error bodies can echo content or credentials.
                    await response.body?.cancel();
                    fail((STATUS[response.status] ?? "http") + " status=" + response.status);
                }
                if (!/^text\/event-stream\s*(;|$)/i.test(response.headers.get("content-type") ?? "")) fail("content-type");
                const parser = Sse.reader(SSE_LIMITS);
                const calls = assembler(context.names);
                const body = response.body.getReader();
                let text = "";
                let finish = null;
                for (;;) {
                    let read;
                    try { read = await body.read(); } catch { fail(controller.signal.aborted ? "cancelled" : "stream-failed"); }
                    if (read.done) fail("stream-truncated");
                    for (const event of parser.push(read.value)) {
                        if (event.event !== "message") fail("chunk-shape");
                        if (event.data === "[DONE]") {
                            const reason = outcome(finish, calls.count);
                            const assembled = calls.complete();
                            commit = () => history.push(entry, { role: "assistant", item: Policy.summary(text, request.sent), text,
                                calls: assembled.map(call => ({ id: call.id, name: call.name, arguments: call.arguments })) });
                            for (const call of assembled)
                                queue.push({ kind: "tool-call", id: call.id, tool: call.tool, arguments: call.parsed });
                            queue.push({ kind: "done", reason });
                            if (state.kind === "streaming") state = { kind: "complete" };
                            wake();
                            return;
                        }
                        const chunk = chunkOf(event.data);
                        if (chunk === null) continue;
                        if (finish !== null) fail("chunk-order");
                        for (const fragment of chunk.fragments) calls.add(fragment);
                        if (chunk.text !== "") {
                            text += chunk.text;
                            queue.push({ kind: "text", text: chunk.text });
                            wake();
                        }
                        finish = chunk.finish;
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

    /** cancel() aborts the live request and resolves once its stream is closed. */
    function cancel() {
        return active === null ? Promise.resolve() : active.cancel();
    }

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
