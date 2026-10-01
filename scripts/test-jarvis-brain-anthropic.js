#!/usr/bin/env node
// Schema-pinned Messages scripts on private loopback through the J09 world.
// Only a disposable provider table substitutes loopback for the vendor origin.
// All keys, images and tool results are synthetic; no SDK or account is used.
"use strict";
const { assert, fs, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const { standins } = require("./fixtures/jarvis/keys-world.js");
const Check = require("./fixtures/schema-check.js");
const excerpt = require("./fixtures/jarvis-brain/anthropic-messages.schema.json");
const fixture = require("./fixtures/jarvis-brain/anthropic-messages-scripts.json");
const http = require("node:http");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const file = path.join(backend, "AnthropicMessages.js");
const KEY = "test-key-must-stay-private";
const PRIVATE = "provider-private-detail";
const clone = value => structuredClone(value);
const start = () => clone(fixture.start);
const text = () => [start(), ...clone(fixture.scripts.text)];
const tools = () => [start(), ...clone(fixture.scripts.tools)];
const end = reason => [
    { type: "message_delta", delta: { stop_reason: reason, stop_sequence: null }, usage: { output_tokens: 1 } },
    { type: "message_stop" }
];
function pinned(name, value) { assert.deepEqual(Check.errors(excerpt, name, value), [], "pinned " + name); }
function encode(value, raw = false) {
    if (typeof value === "string") return value;
    if (!raw) pinned("Event", value);
    return "event: " + value.type + "\ndata: " + JSON.stringify(value) + "\n\n";
}
for (const sequence of Object.values(fixture.scripts)) for (const event of sequence) encode(event);
pinned("Event", fixture.start);

world(async () => {
    const faults = [];
    const records = [];
    const scripts = new Map();
    const doors = [];
    const closes = new WeakMap();
    let counter = 0;
    const server = http.createServer(async (request, response) => {
        const record = { socket: request.socket, url: request.url, headers: request.headers };
        if (!closes.has(request.socket)) closes.set(request.socket, new Promise(resolve => request.socket.once("close", resolve)));
        record.closed = closes.get(request.socket);
        records.push(record);
        try {
            const parts = [];
            for await (const part of request) parts.push(part);
            record.body = JSON.parse(Buffer.concat(parts).toString());
            pinned("Request", record.body);
            assert.equal(request.url, "/v1/messages");
            const sequence = scripts.get(record.body.model);
            assert.ok(sequence, "a scripted model");
            const script = sequence.length > 1 ? sequence.shift() : sequence[0];
            if (script.stall) return;
            if (script.status) {
                const body = { type: "error", error: { type: "fixture_error", message: KEY + " " + PRIVATE } };
                pinned("ErrorResponse", body);
                response.writeHead(script.status, { "content-type": "application/json" });
                response.end(JSON.stringify(body));
                return;
            }
            response.writeHead(200, { "content-type": script.contentType ?? "text/event-stream; charset=utf-8" });
            for (const event of script.events) {
                const bytes = Buffer.from(encode(event, script.raw));
                const cut = Math.floor(bytes.length / 2);
                response.write(bytes.subarray(0, cut));
                response.write(bytes.subarray(cut));
            }
            if (script.reset) {
                await new Promise(resolve => response.write("", resolve));
                request.socket.destroy();
            } else if (!script.hold) response.end();
        } catch (error) { faults.push(error.message); response.destroy(); }
    });
    await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
    const origin = "http://127.0.0.1:" + server.address().port;
    const load = (folder, name) => require(path.join(folder, name));
    function kitFrom(folder, local = true) {
        const table = fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "anthropic-table-"));
        for (const sibling of fs.readdirSync(folder).filter(name => name.endsWith(".js")))
            fs.copyFileSync(path.join(folder, sibling), path.join(table, sibling));
        const source = fs.readFileSync(path.join(folder, "Providers.js"), "utf8");
        const needle = '"https://api.anthropic.com/v1"';
        assert.equal(source.split(needle).length - 1, 1);
        if (local) fs.writeFileSync(path.join(table, "Providers.js"), source.replace(needle, JSON.stringify(origin + "/v1")));
        return { Brain: load(table, "AnthropicMessages.js"), OpenAI: load(table, "OpenAIChat.js"), Policy: load(table, "Policy.js"),
            Net: load(table, "net.js"), Secrets: load(table, "Secrets.js"), Providers: load(table, "Providers.js"),
            production: () => kitFrom(folder, false) };
    }
    const env = Object.fromEntries(["PATH", "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
        "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"].map(name => [name, process.env[name]]));
    const TOOLS = [
        { id: "windows.focus", description: "Focus a window.", parameters: { type: "object", properties: { window: { type: "string" } } } },
        { id: "files.read", description: "Read a file.", parameters: { type: "object", properties: { path: { type: "string" } } } }
    ];
    function open(kit, sequence = [{ events: text() }], { remoteVoice = false, cloudVision = "ask", wrap = door => door, tools: offered = TOOLS } = {}) {
        const provider = kit.Providers.select("anthropic");
        const recipients = kit.Policy.recipients({ conversation: "fixture", profile: "standard", cloudVision,
            brain: { kind: "network", provider: "anthropic", account: "fixture", origin },
            speech: [remoteVoice ? { kind: "network", provider: "voice", account: "fixture", origin: "https://voice.example.test" }
                : { kind: "local", provider: "local", account: "" }] });
        const net = kit.Net.create(recipients);
        doors.push(net);
        const secrets = new kit.Secrets.Secrets(path.join(env.XDG_STATE_HOME, "vgs/jarvis"), env);
        const model = "fixture-" + ++counter;
        scripts.set(model, clone(sequence));
        const brain = kit.Brain.create({ provider, model, net: wrap(net), recipients,
            key: { secrets, reference: kit.Secrets.ownReference("anthropic", "fixture", origin) } });
        brain.start({ instructions: "Fixture guidance.", tools: offered });
        return { brain, recipients, model };
    }
    const speech = (kit, value = "What time is it?") => kit.Policy.item(value, ["speech"]);
    const user = (kit, items = [speech(kit)]) => ({ kind: "user", items });
    const last = () => records.at(-1);
    async function drain(turn) {
        const events = [];
        try { for await (const event of turn.events) events.push(event); return { events, error: null }; }
        catch (error) { return { events, error }; }
    }
    // A missing fixture handshake/close must fail, not hang. This is not a
    // latency budget. Clear the timer after each observed result.
    async function within(promise, label) {
        let timer;
        try { return await Promise.race([promise, new Promise((_, reject) => {
            timer = setTimeout(() => reject(new assert.AssertionError({ message: label + " within 5 s" })), 5000);
        })]); } finally { clearTimeout(timer); }
    }
    async function textTurns(kit) {
        const { brain, model } = open(kit);
        assert.deepEqual(await drain(brain.send(user(kit))), { error: null, events: [
            { kind: "text", text: "Hello" }, { kind: "text", text: " there." }, { kind: "done", reason: "stop" }] });
        assert.deepEqual(last().body, { model, system: "Fixture guidance.", messages: [
            { role: "user", content: [{ type: "text", text: "What time is it?" }] }],
            max_tokens: 4096, stream: true, tools: TOOLS.map(tool =>
                ({ name: tool.id.replaceAll(".", "_"), description: tool.description, input_schema: tool.parameters })) });
        assert.deepEqual([last().headers["x-api-key"], last().headers.authorization, last().headers["anthropic-version"],
            last().headers.accept, last().headers["content-type"]], [KEY, undefined, "2023-06-01", "text/event-stream", "application/json"]);
        await drain(brain.send(user(kit, [speech(kit, "Again")])));
        assert.deepEqual(last().body.messages[1], { role: "assistant", content: [{ type: "text", text: "Hello there." }] });
        brain.start({ instructions: "Restarted.", tools: [] });
        await drain(brain.send(user(kit)));
        assert.equal(last().body.messages.length, 1);
        assert.equal(Object.hasOwn(last().body, "tools"), false);
    }
    const expectedCalls = [
        { kind: "tool-call", id: "toolu_focus", tool: "windows.focus", arguments: { window: "0x1f" } },
        { kind: "tool-call", id: "toolu_read", tool: "files.read", arguments: { path: "/fixture/notes" } }
    ];
    async function toolTurns(kit) {
        const { brain, recipients } = open(kit, [{ events: tools() }, { events: text() }], { remoteVoice: true });
        const reply = await drain(brain.send(user(kit)));
        assert.deepEqual(reply, { error: null, events: [{ kind: "text", text: "Checking." },
            ...expectedCalls, { kind: "done", reason: "tool-calls" }] });
        assert.throws(() => brain.send(user(kit)), { message: "jarvis: brain=tool-results-pending" });
        const results = [{ id: "toolu_read", item: kit.Policy.item("PRIVATE notes", ["file"]) },
            { id: "toolu_focus", item: kit.Policy.item("focused", ["desktop"]) }];
        for (const bad of [[], [results[0]], [results[0], results[0]], [results[0], { ...results[1], id: "stale" }]])
            assert.throws(() => brain.send({ kind: "tool-results", results: bad }), { message: "jarvis: brain=tool-results" });
        assert.throws(() => brain.send({ kind: "tool-results", results, instructions: "Restated." }),
            { message: "jarvis: brain=instructions" }, "Messages has no instruction message after results");
        const turn = brain.send({ kind: "tool-results", results });
        assert.deepEqual(turn.release, { withheld: [], needed: ["file"], labels: ["speech", "desktop"] });
        assert.equal((await drain(turn)).error, null);
        assert.deepEqual(last().body.messages.slice(1), [
            { role: "assistant", content: [{ type: "text", text: "Checking." },
                { type: "tool_use", id: "toolu_focus", name: "windows_focus", input: { window: "0x1f" } },
                { type: "tool_use", id: "toolu_read", name: "files_read", input: { path: "/fixture/notes" } }] },
            { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_focus", content: "focused" },
                { type: "tool_result", tool_use_id: "toolu_read", content: "[withheld: file text]" }] }]);
        await drain(brain.send(user(kit), [{ recipients, labels: ["file"] }]));
        assert.equal(last().body.messages[2].content[1].content, "PRIVATE notes", "result labels survive in history");
        assert.throws(() => brain.send(user(kit)), { message: "jarvis: brain=history-release" });
    }
    const PNG = Buffer.from("89504e470d0a1a0a", "hex");
    async function images(kit) {
        const seen = [];
        const wrap = door => ({ request(item, options, grants) { seen.push(item.labels); return door.request(item, options, grants); } });
        const { brain, recipients } = open(kit, undefined, { remoteVoice: true, wrap });
        const turn = () => ({ kind: "user", items: [speech(kit), kit.Policy.item("PRIVATE notes", ["file"])],
            images: [{ type: "image/png", item: kit.Policy.item(PNG, ["screen"]) }] });
        const asked = brain.send(turn());
        assert.deepEqual(asked.release, { withheld: [], needed: ["file", "screen"], labels: ["speech"] });
        assert.equal((await drain(asked)).error, null);
        assert.deepEqual(last().body.messages[0].content, [
            { type: "text", text: "What time is it?" }, { type: "text", text: "[withheld: file text]" },
            { type: "text", text: "[withheld: screen content]" }]);
        assert.deepEqual(seen.at(-1), ["speech"]);
        const grants = [{ recipients, labels: ["file", "screen"] }];
        await drain(brain.send(user(kit), grants));
        assert.deepEqual(last().body.messages[0].content.at(-1),
            { type: "image", source: { type: "base64", media_type: "image/png", data: PNG.toString("base64") } });
        assert.deepEqual(seen.at(-1), ["speech", "file", "screen"], "image and history labels reach net");
        assert.throws(() => brain.send(user(kit)), { message: "jarvis: brain=history-release" });
        const never = open(kit, undefined, { remoteVoice: true, cloudVision: "never" });
        const withheld = never.brain.send(turn(), [{ recipients: never.recipients, labels: ["screen", "file"] }]);
        assert.deepEqual(withheld.release, { withheld: ["screen"], needed: [], labels: ["speech", "file"] });
        await drain(withheld);
        assert.equal(last().body.messages[0].content.at(-1).text, "[withheld: screen content]");
        const jpeg = open(kit);
        await drain(jpeg.brain.send({ kind: "user", items: [], images: [
            { type: "image/jpeg", item: kit.Policy.item(PNG, ["screen"]) }] }));
        assert.equal(last().body.messages[0].content[0].source.media_type, "image/jpeg");
    }
    async function refused(kit, script, cause) {
        const { brain } = open(kit, [script, { events: text() }]);
        const result = await drain(brain.send(user(kit)));
        assert.ok(result.error, cause + " must fail");
        assert.equal(result.error.message, "jarvis: " + cause);
        assert.equal(result.events.some(event => event.kind === "tool-call" || event.kind === "done"), false);
        assert.equal(result.error.message.includes(KEY) || result.error.message.includes(PRIVATE), false);
        assert.equal((await drain(brain.send(user(kit)))).error, null);
        assert.equal(last().body.messages.length, 1, "failed turns leave no history");
    }
    const altered = (sequence, edit) => { const events = clone(sequence); edit(events); return { events, raw: true }; };
    const refusals = [
        ["lost-json", altered(tools(), events => events.splice(6, 1)), "brain=tool-call-arguments"],
        ["lost-start", altered(tools(), events => events.splice(4, 1)), "brain=event-order"],
        ["lost-stop", altered(tools(), events => events.splice(7, 1)), "brain=block-index"],
        ["overlapping-start", altered(text(), events => events.splice(2, 0, clone(events[1]))), "brain=event-order"],
        ["lost-terminal", { events: tools().slice(0, -1) }, "brain=stream-truncated"],
        ["duplicate-start", { events: [start(), start()] }, "brain=event-order"],
        ["start-content", altered(text(), events => events[0].message.content.push({ type: "text", text: "" })), "brain=event-shape"],
        ["start-role", altered(text(), events => events[0].message.role = "user"), "brain=event-shape"],
        ["start-reason", altered(text(), events => events[0].message.stop_reason = "end_turn"), "brain=event-shape"],
        ["block-gap", altered(tools(), events => events[4].index = 2), "brain=block-index"],
        ["delta-index", altered(tools(), events => events[5].index = 0), "brain=block-index"],
        ["stop-index", altered(tools(), events => events[7].index = 0), "brain=block-index"],
        ["duplicate-id", altered(tools(), events => events[8].content_block.id = "toolu_focus"), "brain=tool-call-id"],
        ["unknown-tool", altered(tools(), events => events[4].content_block.name = "unoffered"), "brain=tool-call-name"],
        ["empty-id", altered(tools(), events => events[4].content_block.id = ""), "brain=block-shape"],
        ["text-shape", altered(text(), events => events[1].content_block.text = 7), "brain=block-shape"],
        ["array-input", altered(tools(), events => events[4].content_block.input = []), "brain=block-shape"],
        ["array-json", altered(tools(), events => { events[5].delta.partial_json = "["; events[6].delta.partial_json = "]"; }), "brain=tool-call-arguments"],
        ["conflict-input", altered(tools(), events => events[4].content_block.input = { unexpected: true }), "brain=tool-call-conflict"],
        ["text-delta", altered(text(), events => events[3].delta.text = 7), "brain=delta-shape"],
        ["tool-delta", altered(tools(), events => events[5].delta.partial_json = 7), "brain=delta-shape"],
        ["delta-type", altered(tools(), events => events[5].delta.type = "text_delta"), "brain=delta-shape"],
        ["unsupported-block", altered(text(), events => events[1].content_block.type = "thinking"), "brain=block-unsupported"],
        ["early-ending", { events: [start(), ...clone(fixture.scripts.hold), ...end("end_turn")] }, "brain=event-order"],
        ["block-after-ending", { events: [...text().slice(0, -1),
            { ...clone(fixture.scripts.text[0]), index: 1 }] }, "brain=event-order"],
        ["stop-before-ending", { events: [start(), { type: "message_stop" }] }, "brain=event-order"],
        ["ending-before-start", { events: end("end_turn") }, "brain=event-order"],
        ["repeated-reason", { events: [...text().slice(0, -1), ...end("end_turn")] }, "brain=event-order"],
        ["missing-reason", { events: [start(), ...end(null)] }, "brain=finish-missing"],
        ["tools-without-call", { events: [start(), ...end("tool_use")] }, "brain=finish reason=tool-use-without-call"],
        ["unanswered-tools", altered(tools(), events => events.at(-2).delta.stop_reason = "end_turn"), "brain=finish reason=unanswered-tools"],
        ["stream-error", { events: [start(), ...fixture.scripts.error] }, "brain=stream-error"],
        ["not-json", { events: ["event: message_start\ndata: {\n\n"] }, "brain=event-json"],
        ["not-object", { events: ["event: message_start\ndata: null\n\n"] }, "brain=event-shape"],
        ["event-name", { events: ["event: ping\ndata: " + JSON.stringify(fixture.start) + "\n\n", ...text().slice(1)] }, "brain=event-shape"],
        ["bad-index", altered(text(), events => events[1].index = -1), "brain=event-shape"],
        ["bad-start-object", altered(text(), events => events[1].content_block = null), "brain=event-shape"],
        ["bad-delta-object", altered(text(), events => events[3].delta = null), "brain=event-shape"],
        ["bad-ending-object", altered(text(), events => events.at(-2).delta = null), "brain=event-shape"],
        ["bad-reason-type", altered(text(), events => events.at(-2).delta.stop_reason = 7), "brain=event-shape"],
        ["not-sse", { events: text(), contentType: "application/json" }, "brain=content-type"],
        ["reset", { events: [start(), ...fixture.scripts.hold], reset: true }, "brain=stream-failed"],
        ...["max_tokens", "refusal", "pause_turn", "model_context_window_exceeded", "unknown"].map(reason =>
            [reason, { events: [start(), ...end(reason)], raw: reason === "unknown" }, "brain=finish reason=" + reason])
    ];
    const refusal = name => kit => {
        const [, script, cause] = refusals.find(row => row[0] === name);
        return refused(kit, script, cause);
    };
    function many(count) {
        return [start(), ...Array.from({ length: count }, (_, index) => [
            { type: "content_block_start", index, content_block: { type: "tool_use", id: "toolu_" + index, name: "windows_focus", input: {} } },
            { type: "content_block_stop", index }]).flat(), ...end("tool_use")];
    }
    async function bounds(kit) {
        const allowed = open(kit, [{ events: many(16) }]);
        const result = await drain(allowed.brain.send(user(kit)));
        assert.equal(result.error, null);
        assert.equal(result.events.filter(event => event.kind === "tool-call").length, 16);
        await refused(kit, { events: many(17) }, "brain=tool-call-limit");
    }
    async function endings(kit) {
        for (const reason of ["end_turn", "stop_sequence"]) {
            const events = text();
            events.at(-2).delta.stop_reason = reason;
            events.splice(2, 0, "event: future_metadata\ndata: {\"type\":\"future_metadata\"}\n\n");
            events.splice(-1, 0, { type: "message_delta", delta: { stop_reason: null, stop_sequence: null }, usage: { output_tokens: 3 } });
            const { brain } = open(kit, [{ events }]);
            assert.equal((await drain(brain.send(user(kit)))).error, null, "future event and cumulative usage");
        }
        const initial = text();
        initial[1].content_block.text = "Start. ";
        const { brain } = open(kit, [{ events: initial }]);
        const reply = await drain(brain.send(user(kit)));
        assert.deepEqual(reply.events.filter(event => event.kind === "text").map(event => event.text),
            ["Start. ", "Hello", " there."], "start text is part of the reply");
        await drain(brain.send(user(kit)));
        assert.equal(last().body.messages[1].content[0].text, "Start. Hello there.");
    }
    async function cancellation(kit, leak = false) {
        const held = { events: [start(), ...fixture.scripts.hold], hold: true };
        const wrap = door => ({ request: async (item, options, grants) => {
            if (!leak) return door.request(item, options, grants);
            const answer = await door.request(item, { ...options, signal: undefined }, grants);
            const reader = answer.response.body.getReader();
            const body = new ReadableStream({ start(source) {
                options.signal.addEventListener("abort", () => source.error(new Error("fixture abort")), { once: true });
            }, async pull(source) { const read = await reader.read(); if (read.done) source.close(); else source.enqueue(read.value); } });
            return { kind: "response", response: new Response(body, { headers: answer.response.headers }), close() {} };
        } });
        for (const mode of ["cancel", "return", "close"]) {
            const { brain } = open(kit, [held, { events: text() }], { wrap });
            const turn = brain.send(user(kit));
            assert.deepEqual(await turn.events.next(), { value: { kind: "text", text: "Thinking" }, done: false });
            const record = last();
            if (mode === "cancel") await within(brain.cancel(), "ack");
            else if (mode === "return") await within(turn.events.return(), "return");
            else brain.close();
            await within(record.closed, "server close");
            await assert.rejects(turn.events.next(), { message: "jarvis: brain=cancelled" });
            if (mode !== "close") {
                await drain(brain.send(user(kit)));
                assert.deepEqual(last().body.messages.map(message => message.role), ["user", "user"],
                    "a sent, cancelled turn stays unanswered without its partial reply");
            }
        }
    }
    async function races(kit) {
        for (const sequence of ["buffered", "terminal-race", "delayed-abort"]) {
            let source;
            let reading;
            let closed = false;
            let ended = false;
            const waiting = new Promise(resolve => { reading = resolve; });
            const wrap = () => ({ request: async (_item, options) => {
                const body = new ReadableStream({ start(controller) {
                    source = controller;
                    if (sequence === "buffered") source.enqueue(Buffer.from([start(), ...fixture.scripts.hold].map(event => encode(event)).join("")));
                    options.signal.addEventListener("abort", () => {
                        const finish = () => { ended = true; source.error(new Error("fixture abort")); };
                        if (sequence === "delayed-abort") setTimeout(finish, 10); else finish();
                    }, { once: true });
                }, pull() { reading(); } }, { highWaterMark: 0 });
                return { kind: "response", response: new Response(body, { headers: { "content-type": "text/event-stream" } }),
                    close() { closed = true; } };
            } });
            const { brain } = open(kit, undefined, { wrap });
            const turn = brain.send(user(kit));
            const pending = turn.events.next();
            if (sequence === "buffered") assert.equal((await pending).value.text, "Thinking");
            else {
                // Attach rejection handling before cancellation resolves the read.
                const rejected = assert.rejects(pending, { message: "jarvis: brain=cancelled" });
                await within(waiting, "reader");
                if (sequence === "terminal-race") source.enqueue(Buffer.from(text().map(event => encode(event)).join("")));
                await within(brain.cancel(), "ack");
                await rejected;
            }
            if (sequence === "buffered") await within(brain.cancel(), "ack");
            assert.equal(closed, true, "ack closes net response");
            assert.equal(ended, true, "ack follows stream teardown");
            if (sequence === "buffered") await assert.rejects(turn.events.next(), { message: "jarvis: brain=cancelled" });
        }
        const { brain } = open(kit, [{ stall: true }]);
        const turn = brain.send(user(kit));
        const count = records.length;
        const pending = assert.rejects(turn.events.next(), { message: "jarvis: brain=cancelled" });
        // Poll only for receipt of fixture headers, never for production latency.
        await within(new Promise(resolve => { const poll = () => records.length > count ? resolve() : setTimeout(poll, 10); poll(); }), "request");
        const record = last();
        await within(brain.cancel(), "ack before headers");
        await within(record.closed, "server close before headers");
        await pending;
        const unstarted = open(kit).brain;
        const before = records.length;
        const abandoned = unstarted.send(user(kit));
        await unstarted.cancel();
        await assert.rejects(abandoned.events.next(), { message: "jarvis: brain=cancelled" });
        assert.equal(records.length, before);
    }
    async function drivers(kit) {
        kit = kit.production();
        const Providers = kit.Providers;
        const Policy = kit.Policy;
        const recipients = Policy.recipients({ conversation: "fixture", profile: "standard", cloudVision: "ask",
            brain: { kind: "network", provider: "anthropic", account: "fixture", origin: "https://api.anthropic.com" },
            speech: [{ kind: "local", provider: "local", account: "" }] });
        const secrets = new kit.Secrets.Secrets(path.join(env.XDG_STATE_HOME, "vgs/jarvis"), env);
        const sent = [];
        let closed = false;
        const options = { provider: Providers.select("anthropic"), model: "fixture-model", recipients,
            key: { secrets, reference: kit.Secrets.ownReference("anthropic", "fixture", "https://api.anthropic.com") },
            net: { request: async (item, value) => {
                sent.push(value);
                return { kind: "response", response: new Response(text().map(event => encode(event)).join(""),
                    { headers: { "content-type": "text/event-stream" } }), close() { closed = true; } };
            } } };
        assert.throws(() => kit.Brain.create({ ...options, provider: Providers.select("openai") }), { message: "jarvis: brain=driver" });
        assert.throws(() => kit.OpenAI.create(options), { message: "jarvis: brain=driver" });
        assert.throws(() => kit.Brain.create({ ...options, key: null }), { message: "jarvis: brain=no-key" });
        assert.throws(() => kit.Brain.create({ ...options, key: { secrets, reference:
            kit.Secrets.ownReference("anthropic", "fixture", origin) } }), { message: "jarvis: net=key-origin" });
        const brain = kit.Brain.create(options);
        brain.start({ instructions: "Fixture guidance.", tools: [] });
        assert.equal((await drain(brain.send(user(kit)))).error, null);
        assert.deepEqual([sent[0].url, sent[0].key.header, sent[0].key.prefix, sent[0].key.origin, sent[0].key.value],
            ["https://api.anthropic.com/v1/messages", "x-api-key", "", "https://api.anthropic.com", KEY]);
        assert.equal(closed, true);
    }
    try {
        const kit = kitFrom(backend);
        for (const check of [textTurns, toolTurns, images, bounds, endings, cancellation, races, drivers]) await check(kit);
        for (const [name] of refusals) await refusal(name)(kit);
        const statuses = [[400, "request-rejected"], [401, "unauthorized"], [402, "billing"], [403, "forbidden"],
            [404, "not-found"], [409, "conflict"], [413, "request-too-large"], [429, "rate-limited"],
            [500, "provider-error"], [504, "timeout"], [529, "overloaded"], [502, "http"]];
        for (const [status, cause] of statuses) await refused(kit, { status }, "brain=" + cause + " status=" + status);
        assert.deepEqual(faults, [], "all requests matched the vendor schema");
        await assert.rejects(() => cancellation(kit, true), { message: "server close within 5 s" });
        let controls = 0;
        async function control(name, needle, replacement, check, target = file) {
            await mutant(target, name, needle, replacement, async (_module, folder) => check(kitFrom(folder)), "AnthropicMessages.js");
            controls++;
        }
        const mutations = [
            ["wire-tool-schema", "input_schema: structuredClone(tool.parameters)", "input_schema: {}", textTurns],
            ["system", "({ model, system, messages, max_tokens: 4096, stream: true })", "({ model, messages, max_tokens: 4096, stream: true })", textTurns],
            ["tokens", "max_tokens: 4096", "max_tokens: 1", textTurns],
            ["version", '"anthropic-version": "2023-06-01"', '"anthropic-version": "wrong"', textTurns],
            ["key-header", 'header: "x-api-key"', 'header: "authorization"', drivers],
            ["endpoint", 'path: "/messages"', 'path: "/chat/completions"', drivers],
            ["history-blocks", "content: entry.content", 'content: [{ type: "text", text: entry.text }]', toolTurns],
            ["result-id", "tool_use_id: result.id", 'tool_use_id: "wrong"', toolTurns],
            ["result-role", 'results => [{ role: "user"', 'results => [{ role: "assistant"', toolTurns],
            ["image-media", "media_type: image.type", 'media_type: "image/png"', images],
            ["image-base64", 'image.decision.content.toString("base64")', 'image.decision.content.toString("hex")', images],
            ["image-marker", 'image.decision.kind === "send"', "true", images],
            ["terminal-required", "            block = null;\n            break;",
                '            block = null;\n            return { kind: "complete", text, calls, content, reason: "stop" };', refusal("lost-terminal")],
            ["json", 'try { parsed = JSON.parse(block.fragments); } catch { fail("tool-call-arguments"); }',
                "try { parsed = JSON.parse(block.fragments); } catch { parsed = {}; }", refusal("lost-json")],
            ["object-json", 'if (!plain(parsed)) fail("tool-call-arguments");', "", refusal("array-json")],
            ["input-conflict", 'if (Object.keys(block.input).length !== 0) fail("tool-call-conflict");', "", refusal("conflict-input")],
            ["id", 'if (calls.some(call => call.id === start.id)) fail("tool-call-id");', "", refusal("duplicate-id")],
            ["name", 'if (!names.has(start.name)) fail("tool-call-name");', "", refusal("unknown-tool")],
            ["call-limit", "calls.length === TOOL_CALLS", "calls.length > TOOL_CALLS", bounds],
            ["call-limit-low", "TOOL_CALLS = 16", "TOOL_CALLS = 15", bounds],
            ["tool-mapping", "tool: names.get(block.name)", "tool: block.name", toolTurns],
            ["block-index", '&& value.index !== content.length', "&& false", refusal("block-gap")],
            ["initial-order", 'if (phase !== "initial") fail("event-order");', "", refusal("duplicate-start")],
            ["start-order", 'if (phase !== "blocks" || block !== null) fail("event-order");', "", refusal("overlapping-start")],
            ["delta-order", 'if (phase !== "blocks" || block === null) fail("event-order");\n            switch (block.kind) {\n            case "text":\n                if (value.delta',
                'switch (block.kind) {\n            case "text":\n                if (value.delta', refusal("lost-start")],
            ["stop-order", 'if (phase !== "blocks" || block === null) fail("event-order");\n            switch (block.kind) {\n            case "text": content.push',
                'switch (block.kind) {\n            case "text": content.push', kit => refused(kit,
                    { events: [start(), { type: "content_block_stop", index: 0 }] }, "brain=event-order")],
            ["ending-order", 'if (phase === "initial" || block !== null) fail("event-order");', "", refusal("ending-before-start")],
            ["terminal-order", 'if (phase !== "ending" || block !== null) fail("event-order");', "", refusal("stop-before-ending")],
            ["reason-order", 'if (reason !== null) fail("event-order");', "", refusal("repeated-reason")],
            ["unknown-block", 'default: return fail("block-unsupported");', 'default: block = {kind: "text", text: ""}; break;', refusal("unsupported-block")],
            ["finish-missing", 'case null: return fail("finish-missing");', 'case null: return "stop";', refusal("missing-reason")],
            ["finish-call", 'if (count === 0) fail("finish reason=tool-use-without-call");', "", refusal("tools-without-call")],
            ["finish-no-call", 'if (count !== 0) fail("finish reason=unanswered-tools");', "", refusal("unanswered-tools")],
            ["stream-error", 'case "error": return fail("stream-error");', 'case "error": break;', refusal("stream-error")],
            ["event-json", 'try { value = JSON.parse(event.data); } catch { fail("event-json"); }', "value = JSON.parse(event.data);", refusal("not-json")],
            ["event-name", " || value.type !== event.event", "", refusal("event-name")],
            ["event-object", "!plain(value) || ", "", refusal("not-object")],
            ["start-object", "!plain(value.message) || ", "", kit => refused(kit,
                altered(text(), events => events[0].message = null), "brain=event-shape")],
            ["start-role", 'value.message.role !== "assistant"', "false", refusal("start-role")],
            ["start-reason", "|| value.message.stop_reason !== null", "|| false", refusal("start-reason")],
            ["start-content-array", "!Array.isArray(value.message.content) || ", "", kit => refused(kit,
                altered(text(), events => events[0].message.content = ""), "brain=event-shape")],
            ["index-integer", "!Number.isSafeInteger(value.index) || ", "", kit => refused(kit,
                altered(text(), events => events[1].index = 0.5), "brain=event-shape")],
            ["index-shape", " || value.index < 0", "", refusal("bad-index")],
            ["block-object", 'value.type === "content_block_start" && !plain(value.content_block)', "false", refusal("bad-start-object")],
            ["delta-object", 'value.type === "content_block_delta" && !plain(value.delta)', "false", refusal("bad-delta-object")],
            ["ending-object", "!plain(value.delta) || ", "", refusal("bad-ending-object")],
            ["ending-reason-type", '&& typeof value.delta.stop_reason !== "string"', "&& false", refusal("bad-reason-type")],
            ["message-content", " || value.message.content.length !== 0", "", refusal("start-content")],
            ["text-block-shape", 'if (typeof start.text !== "string") fail("block-shape");', "", refusal("text-shape")],
            ["tool-block-id", ' || start.id === ""', "", refusal("empty-id")],
            ["tool-block-input", "|| !plain(start.input)", "|| false", refusal("array-input")],
            ["text-delta-shape", ' || typeof value.delta.text !== "string"', "", refusal("text-delta")],
            ["text-delta-type", 'value.delta.type !== "text_delta" || ', "", kit => refused(kit,
                altered(text(), events => events[3].delta.type = "input_json_delta"), "brain=delta-shape")],
            ["tool-delta-type", 'value.delta.type !== "input_json_delta" || ', "", refusal("delta-type")],
            ["tool-delta-shape", ' || typeof value.delta.partial_json !== "string"', "", refusal("tool-delta")],
            ["driver", 'if (provider.driver !== protocol.driver) fail("driver");', "", drivers, path.join(backend, "WireBrain.js")],
            ["instruction-encoder", " || protocol.instruction === undefined", "", toolTurns, path.join(backend, "WireBrain.js")]
        ];
        for (const [name, needle, replacement, check, target] of mutations) await control(name, needle, replacement, check, target);
        for (const reason of ["max_tokens", "refusal", "pause_turn", "model_context_window_exceeded", "unknown"])
            await control("finish-" + reason, 'default: return fail("finish reason="', 'default: return "stop"; return fail("finish reason="', refusal(reason));
        for (const [status, cause] of statuses.filter(([status]) => status !== 502))
            await control("status-" + status, status + ': "' + cause + '"', status + ': "wrong"',
                kit => refused(kit, { status }, "brain=" + cause + " status=" + status));
        assert.deepEqual(faults, [], "controls also sent schema-pinned requests");
        console.log("test-jarvis-brain-anthropic: ok refusals=" + refusals.length + " controls=" + controls + " requests=" + records.length);
    } finally {
        for (const door of doors) door.close();
        for (const record of records) record.socket.destroy();
        await new Promise(resolve => server.close(resolve));
    }
}, standins)?.catch(error => { console.error(error); process.exitCode = 1; });
