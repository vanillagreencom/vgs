#!/usr/bin/env node
// The OpenAI-compatible brain driver against schema-pinned scripts, replayed
// by loopback servers inside the J09 world. Scripts and the excerpt name their
// source and date: scripts/fixtures/jarvis-brain/. The key is the keys-world
// stand-in's fixture value; no network, account or host secret store is used.
"use strict";
const { assert, fs, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const { standins } = require("./fixtures/jarvis/keys-world.js");
const Check = require("./fixtures/schema-check.js");
const excerpt = require("./fixtures/jarvis-brain/openai-chat.schema.json");
const fixtures = require("./fixtures/jarvis-brain/openai-chat-scripts.json");
const http = require("node:http");
const sockets = require("node:net");
const cp = require("node:child_process");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const file = path.join(backend, "OpenAIChat.js");
const KEY = "test-key-must-stay-private";
const PRIVATE = "provider-private-detail";

function kitFrom(folder) {
    const load = name => require(path.join(folder, name));
    return { Brain: load("OpenAIChat.js"), Policy: load("Policy.js"), Providers: load("Providers.js"),
        Net: load("net.js"), Secrets: load("Secrets.js") };
}

const BASE = { id: "chatcmpl-fixture", object: "chat.completion.chunk", created: 1790000000, model: "fixture-model" };
function pinned(name, value, label) {
    assert.deepEqual(Check.errors(excerpt, name, value), [], label + " matches the pinned " + name);
}
// A frame is a script entry or a raw string that is deliberately outside
// the pinned schema. Schema-shaped frames are validated before they are sent.
function encode(frame, label) {
    if (frame === "[DONE]") return "data: [DONE]\n\n";
    if (typeof frame === "string") return frame;
    if (Object.hasOwn(frame, "error")) {
        pinned("ErrorResponse", frame, label);
        return "data: " + JSON.stringify(frame) + "\n\n";
    }
    const chunk = Object.hasOwn(frame, "usage") ? { ...BASE, choices: [], usage: frame.usage }
        : { ...BASE, choices: [{ index: 0, delta: frame.delta, finish_reason: frame.finish_reason }] };
    pinned("CreateChatCompletionStreamResponse", chunk, label);
    return "data: " + JSON.stringify(chunk) + "\n\n";
}
const delta = (value, finish = null) => ({ delta: value, finish_reason: finish });
const scripts = { ...fixtures.scripts,
    "line-limit": { frames: [delta({ content: "x".repeat(1024 * 1024) }), delta({}, "stop"), "[DONE]"] },
    "total-limit": { frames: [...Array(9).fill(delta({ content: "y".repeat(1000000) })), delta({}, "stop"), "[DONE]"] },
    "tool-call-limit": { frames: [...Array.from({ length: 17 }, (_, index) => delta({ tool_calls: [{ index, id: "call_" + index,
        type: "function", function: { name: "windows_focus", arguments: "{}" } }] })), delta({}, "tool_calls"), "[DONE]"] }
};
// [script, raw frame, keyed cause]: frames a broken server could send.
const malformed = [
    ["not-json", "data: {\"choices\":\n\n", "chunk-json"],
    ["not-object", "data: null\n\n", "chunk-shape"],
    ["no-choices", "data: {}\n\n", "chunk-shape"],
    ["two-choices", "data: " + JSON.stringify({ ...BASE, choices: [{ index: 0, delta: {}, finish_reason: null }, { index: 1, delta: {}, finish_reason: null }] }) + "\n\n", "chunk-shape"],
    ["choice-index", "data: " + JSON.stringify({ ...BASE, choices: [{ index: 1, delta: { content: "x" }, finish_reason: null }] }) + "\n\n", "chunk-shape"],
    ["content-type", "data: " + JSON.stringify({ ...BASE, choices: [{ index: 0, delta: { content: 7 }, finish_reason: null }] }) + "\n\n", "chunk-shape"],
    ["finish-type", "data: " + JSON.stringify({ ...BASE, choices: [{ index: 0, delta: {}, finish_reason: 1 }] }) + "\n\n", "chunk-shape"],
    ["fragment-index", "data: " + JSON.stringify({ ...BASE, choices: [{ index: 0, delta: { tool_calls: [{ index: -1, id: "c", function: { name: "windows_focus" } }] }, finish_reason: null }] }) + "\n\n", "chunk-shape"],
    ["fragment-type", "data: " + JSON.stringify({ ...BASE, choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: "c", type: "custom", function: { name: "windows_focus" } }] }, finish_reason: null }] }) + "\n\n", "chunk-shape"],
    ["finish-unknown", "data: " + JSON.stringify({ ...BASE, choices: [{ index: 0, delta: {}, finish_reason: "paused" }] }) + "\n\ndata: [DONE]\n\n", "chunk-shape"],
    ["event-type", "event: delta\ndata: " + JSON.stringify({ ...BASE, choices: [{ index: 0, delta: { content: "x" }, finish_reason: null }] }) + "\n\n", "chunk-shape"]
];
for (const [name, frame] of malformed) scripts["malformed-" + name] = { frames: [frame] };
for (const [name, script] of Object.entries(fixtures.scripts)) {
    for (const frame of script.frames ?? []) encode(frame, name);
    if (script.status !== undefined) pinned("ErrorResponse", script.body, name);
}

world(async () => {
    const ip = cp.spawnSync(path.join(process.env.JARVIS_TEST_ROOT, "bootstrap/ip"),
        ["addr", "add", "192.0.2.1/32", "dev", "lo"], { env: { PATH: process.env.PATH }, encoding: "utf8" });
    assert.equal(ip.status, 0, ip.stderr);
    const clients = [];
    const originalConnect = sockets.Socket.prototype.connect;
    // Observe the real socket creator; the transport under test is unchanged.
    sockets.Socket.prototype.connect = function (...args) {
        // A destroyed socket no longer reports its port; keep it from connect.
        const client = { socket: this, port: null };
        clients.push(client);
        this.once("connect", () => { client.port = this.localPort; });
        return Reflect.apply(originalConnect, this, args);
    };
    const records = [];
    const faults = [];
    const counters = new Map();
    let conversations = 0;
    // One close observation per connection; keep-alive serves several requests.
    const closes = new WeakMap();
    function closing(socket) {
        if (!closes.has(socket)) closes.set(socket, new Promise(resolve => socket.once("close", resolve)));
        return closes.get(socket);
    }
    function server(host) {
        return http.createServer(async (request, response) => {
            const record = { host, url: request.url, headers: request.headers, body: null, socket: request.socket,
                peer: request.socket.remotePort, closed: closing(request.socket) };
            records.push(record);
            try {
                const chunks = [];
                for await (const chunk of request) chunks.push(chunk);
                record.body = JSON.parse(Buffer.concat(chunks).toString());
                const suffix = "/chat/completions";
                if (!request.url.endsWith(suffix)) throw new Error("path " + request.url);
                const route = request.url.slice(0, -suffix.length);
                // A custom base is /<scripts>/<conversation>: each conversation
                // replays its own comma-separated sequence from the start.
                const sequence = route === "/v1" ? ["text"] : route.split("/")[1].split(",");
                const count = counters.get(route) ?? 0;
                counters.set(route, count + 1);
                const name = sequence[Math.min(count, sequence.length - 1)];
                const script = scripts[name];
                if (script === undefined) throw new Error("script " + name);
                record.script = name;
                const extensions = record.extensions ?? {};
                const body = { ...record.body };
                for (const key of Object.keys(extensions)) delete body[key];
                const problems = Check.errors(excerpt, "CreateChatCompletionRequest", body);
                if (problems.length) throw new Error("request " + problems.join("; "));
                if (script.stall) return;
                if (script.status !== undefined) {
                    response.writeHead(script.status, { "content-type": "application/json" });
                    response.end(JSON.stringify(script.body));
                    return;
                }
                response.writeHead(200, { "content-type": script.contentType ?? "text/event-stream; charset=utf-8" });
                for (const frame of script.frames) {
                    // Split every frame so the reader reassembles across reads.
                    const bytes = Buffer.from(encode(frame, name));
                    const cut = Math.floor(bytes.length / 2);
                    response.write(bytes.subarray(0, cut));
                    response.write(bytes.subarray(cut));
                }
                if (!script.hold) response.end();
            } catch (error) {
                faults.push(error.message);
                response.destroy();
            }
        });
    }
    const listeners = [["127.0.0.1", 0], ["127.0.0.1", 0], ["192.0.2.1", 0],
        ["127.0.0.1", 11434], ["127.0.0.1", 8080], ["127.0.0.1", 1234]].map(([host, port]) => {
        const instance = server(host);
        return { instance, ready: new Promise((resolve, reject) => {
            instance.once("error", reject);
            instance.listen(port, host, resolve);
        }) };
    });
    await Promise.all(listeners.map(item => item.ready));
    const [first, second, remote] = listeners.slice(0, 3).map(({ instance }) =>
        "http://" + instance.address().address + ":" + instance.address().port);
    const doors = [];
    const childEnv = {};
    for (const name of ["PATH", "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
        "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]) childEnv[name] = process.env[name];
    const lookups = () => {
        const calls = path.join(process.env.XDG_STATE_HOME, "secret-calls");
        return fs.existsSync(calls) ? fs.readFileSync(calls, "utf8").trim().split("\n").filter(line =>
            JSON.parse(line).argv[0] === "lookup").length : 0;
    };
    // The bound is for a missing close or a hung control, not a latency budget.
    const within = (promise, label) => Promise.race([promise, new Promise((_, reject) =>
        setTimeout(() => reject(new assert.AssertionError({ message: label + " within 5 s" })), 5000))]);

    const TOOLS = [
        { id: "windows.focus", description: "Focus a window.", parameters: { type: "object", properties: { window: { type: "string" } }, required: ["window"] } },
        { id: "files.read", description: "Read a file.", parameters: { type: "object", properties: { path: { type: "string" } }, required: ["path"] } }
    ];
    function open(kit, { id = "custom", base = null, voice = null, key = null, profile = "standard", cloudVision = "ask",
        wrap = door => door, tools = TOOLS } = {}) {
        const provider = kit.Providers.select(id, base === null ? "" : base + "/" + ++conversations);
        const recipients = kit.Policy.recipients({ conversation: "fixture", profile, cloudVision,
            brain: { kind: "network", provider: id, account: "fixture", origin: kit.Net.endpoint(provider.base).origin },
            speech: [voice === null ? { kind: "local", provider: "local", account: "" }
                : { kind: "network", provider: "voice", account: "fixture", origin: voice }] });
        const door = kit.Net.create(recipients);
        doors.push(door);
        const brain = kit.Brain.create({ provider, model: "fixture-model", net: wrap(door), recipients, key });
        brain.start({ instructions: "Fixture guidance.", tools });
        return { brain, recipients, provider };
    }
    const speech = (kit, text = "What time is it?") => kit.Policy.item(text, ["speech"]);
    const user = (kit, ...items) => ({ kind: "user", items: items.length ? items : [speech(kit)] });
    async function drain(turn) {
        const events = [];
        try {
            for await (const event of turn.events) events.push(event);
            return { events, error: null };
        } catch (error) { return { events, error }; }
    }
    const last = () => records.at(-1);
    const PNG = Buffer.from("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489", "hex");

    async function textTurns(kit) {
        const { brain } = open(kit, { base: first + "/text" });
        const turn = brain.send(user(kit));
        assert.deepEqual(turn.release, { withheld: [], needed: [] });
        assert.deepEqual(await drain(turn), { error: null, events: [
            { kind: "text", text: "Hello" }, { kind: "text", text: " there." }, { kind: "done", reason: "stop" }] });
        assert.deepEqual(last().body.messages, [{ role: "system", content: "Fixture guidance." },
            { role: "user", content: "What time is it?" }]);
        assert.deepEqual([last().body.model, last().body.stream, Object.hasOwn(last().body, "store")], ["fixture-model", true, false]);
        assert.deepEqual(last().body.tools.map(tool => tool.function.name), ["windows_focus", "files_read"]);
        assert.deepEqual([last().headers.accept, last().headers["content-type"], last().headers.authorization],
            ["text/event-stream", "application/json", undefined]);
        await drain(brain.send(user(kit, speech(kit, "And now?"))));
        assert.deepEqual(last().body.messages.slice(1), [{ role: "user", content: "What time is it?" },
            { role: "assistant", content: "Hello there." }, { role: "user", content: "And now?" }], "a done turn enters history");
    }

    async function toolTurns(kit) {
        const { brain } = open(kit, { base: first + "/tool-calls,after-tools" });
        assert.deepEqual(await drain(brain.send(user(kit))), { error: null, events: [
            { kind: "tool-call", id: "call_focus", tool: "windows.focus", arguments: { window: "0x1f" } },
            { kind: "tool-call", id: "call_read", tool: "files.read", arguments: { path: "/home/user/notes" } },
            { kind: "done", reason: "tool-calls" }] });
        const count = records.length;
        assert.throws(() => brain.send(user(kit)), { message: "jarvis: brain=tool-results-pending" });
        for (const results of [[], [{ id: "call_focus", item: speech(kit) }],
            [{ id: "call_focus", item: speech(kit) }, { id: "call_stale", item: speech(kit) }],
            [{ id: "call_focus", item: speech(kit) }, { id: "call_focus", item: speech(kit) }]])
            assert.throws(() => brain.send({ kind: "tool-results", results }), { message: "jarvis: brain=tool-results" });
        assert.throws(() => brain.send({ kind: "tool-results", results: [{ id: "call_focus", item: kit.Policy.item(Buffer.from("x"), ["desktop"]) },
            { id: "call_read", item: speech(kit) }] }), { message: "jarvis: brain=item-text" });
        assert.equal(records.length, count, "refused turns send nothing");
        const done = await drain(brain.send({ kind: "tool-results", results: [
            { id: "call_read", item: kit.Policy.item("notes text", ["file"]) },
            { id: "call_focus", item: kit.Policy.item("focused", ["desktop"]) }] }));
        assert.deepEqual(done.events.at(-1), { kind: "done", reason: "stop" });
        assert.deepEqual(last().body.messages.slice(2), [
            { role: "assistant", content: null, tool_calls: [
                { id: "call_focus", type: "function", function: { name: "windows_focus", arguments: "{\"window\": \"0x1f\"}" } },
                { id: "call_read", type: "function", function: { name: "files_read", arguments: "{\"path\":\"/home/user/notes\"}" } }] },
            { role: "tool", tool_call_id: "call_focus", content: "focused" },
            { role: "tool", tool_call_id: "call_read", content: "notes text" }]);
    }

    async function refused(kit, script, cause) {
        const { brain } = open(kit, { base: first + "/" + script });
        const { events, error } = await drain(brain.send(user(kit)));
        assert.ok(error, script + " must fail");
        assert.equal(error.message, "jarvis: " + cause, script);
        assert.equal(events.some(event => event.kind === "tool-call" || event.kind === "done"), false, script + " yields no call or done");
        assert.equal(JSON.stringify(error.message).includes(PRIVATE), false);
        return brain;
    }
    const refusals = [
        ["tool-call-lost-middle", "brain=tool-call-arguments"], ["tool-call-lost-start", "brain=tool-call-start"],
        ["tool-call-lost-call", "brain=tool-call-index"], ["tool-call-conflict", "brain=tool-call-conflict"],
        ["tool-call-duplicate-id", "brain=tool-call-id"], ["tool-call-unknown", "brain=tool-call-name"],
        ["tool-call-array", "brain=tool-call-arguments"], ["tool-call-limit", "brain=tool-call-limit"],
        ["tool-calls-without-call", "brain=finish reason=tool-calls-without-call"],
        ["stop-with-tool-calls", "brain=finish reason=stop-with-tool-calls"], ["finish-length", "brain=finish reason=length"],
        ["finish-content-filter", "brain=finish reason=content-filter"], ["finish-function-call", "brain=finish reason=function-call"],
        ["finish-missing", "brain=finish-missing"], ["chunk-after-finish", "brain=chunk-order"], ["refusal", "brain=refusal"],
        ["stream-error", "brain=stream-error"], ["truncated", "brain=stream-truncated"], ["not-sse", "brain=content-type"],
        ["line-limit", "sse=line-limit"], ["total-limit", "sse=total-limit"],
        ["http-400", "brain=request-rejected status=400"], ["http-401", "brain=unauthorized status=401"],
        ["http-403", "brain=forbidden status=403"], ["http-404", "brain=not-found status=404"],
        ["http-429", "brain=rate-limited status=429"], ["http-500", "brain=provider-error status=500"],
        ["http-503", "brain=unavailable status=503"],
        ...malformed.map(([name, , cause]) => ["malformed-" + name, "brain=" + cause])
    ];
    const refusal = name => kit => refused(kit, name, refusals.find(row => row[0] === name)[1]);
    async function failedTurnKeepsHistory(kit) {
        const { brain } = open(kit, { base: first + "/truncated,text" });
        assert.equal((await drain(brain.send(user(kit)))).error.message, "jarvis: brain=stream-truncated");
        await drain(brain.send(user(kit, speech(kit, "Again"))));
        assert.deepEqual(last().body.messages.slice(1), [{ role: "user", content: "Again" }], "a failed turn leaves no history");
    }

    async function keys(kit) {
        const store = new kit.Secrets.Secrets(path.join(childEnv.XDG_STATE_HOME, "vgs/jarvis"), childEnv);
        const handed = [];
        const secrets = { lookup: reference => { const value = store.lookup(reference); handed.push(value); return value; } };
        const reference = kit.Secrets.ownReference("fixture", "test", first);
        const before = lookups();
        const { brain } = open(kit, { base: first + "/text", voice: second, key: { secrets, reference } });
        const turn = brain.send(user(kit));
        assert.equal(lookups(), before, "no lookup before the first request leaves");
        await drain(turn);
        await drain(brain.send(user(kit)));
        assert.equal(lookups(), before + 1, "one lookup for the conversation");
        assert.equal(last().headers.authorization, "Bearer " + KEY);
        assert.equal(records.some(record => record.host === "127.0.0.1" && record.url.startsWith("/") && record.headers.host === new URL(second).host), false,
            "the speech origin never receives a request");
        brain.close();
        assert.ok(handed.length === 1 && handed[0].every(byte => byte === 0), "close zeroes the looked-up key");
        assert.throws(() => brain.send(user(kit)), { message: "jarvis: brain=closed" });
        const count = records.length;
        const elsewhere = kit.Secrets.ownReference("fixture", "test", second);
        const bound = open(kit, { base: first + "/text", voice: second, key: { secrets: store, reference: elsewhere } });
        const { error } = await drain(bound.brain.send(user(kit)));
        assert.equal(error.message, "jarvis: net=key-origin", "a key bound to another origin is refused");
        assert.equal(records.length, count, "neither origin receives the refused request");
        assert.throws(() => open(kit, { id: "openai" }), { message: "jarvis: brain=no-key" });
    }

    async function release(kit) {
        const seen = [];
        const wrap = door => ({ request: (item, options, grants) => { seen.push(item.labels); return door.request(item, options, grants); } });
        const conversation = open(kit, { base: remote + "/text", wrap });
        const file = kit.Policy.item("PRIVATE file text", ["file"]);
        const abandoned = conversation.brain.send(user(kit, speech(kit), file));
        assert.deepEqual(abandoned.release, { withheld: [], needed: ["file"] });
        const count = records.length;
        await abandoned.events.return();
        assert.equal(records.length, count, "an abandoned turn sends nothing");
        await drain(conversation.brain.send(user(kit, speech(kit), file)));
        assert.equal(last().body.messages[1].content, "What time is it?\n\n[withheld: file text]");
        assert.equal(JSON.stringify(last().body).includes("PRIVATE"), false);
        assert.deepEqual(seen.at(-1), ["speech"], "the request item carries only included labels");
        const grants = [{ recipients: conversation.recipients, labels: ["file"] }];
        const granted = conversation.brain.send(user(kit, speech(kit, "Now?")), grants);
        assert.deepEqual(granted.release, { withheld: [], needed: [] });
        await drain(granted);
        assert.equal(last().body.messages[1].content, "What time is it?\n\nPRIVATE file text", "a later grant releases history");
        assert.deepEqual(seen.at(-1), ["speech", "file"]);
        assert.throws(() => conversation.brain.send(user(kit, speech(kit, "Later"))), { message: "jarvis: brain=history-release" },
            "a reply that carries a granted label needs that grant");
        const only = open(kit, { base: remote + "/text" });
        assert.throws(() => only.brain.send(user(kit, file)), { message: "jarvis: brain=release-empty" });
        const never = open(kit, { base: remote + "/text", profile: "trusted", cloudVision: "never" });
        const screen = never.brain.send(user(kit, speech(kit), kit.Policy.item("PRIVATE screen text", ["screen"])));
        assert.deepEqual(screen.release, { withheld: ["screen"], needed: [] });
        await drain(screen);
        assert.equal(last().body.messages[1].content, "What time is it?\n\n[withheld: screen content]");
    }

    async function images(kit) {
        const { brain } = open(kit, { id: "ollama" });
        const image = kit.Policy.item(PNG, ["screen"]);
        await drain(brain.send({ kind: "user", items: [speech(kit, "What is this?")], images: [{ type: "image/png", item: image }] }));
        assert.equal(last().url, "/v1/chat/completions");
        assert.deepEqual(last().body.messages[1].content, [{ type: "text", text: "What is this?" },
            { type: "image_url", image_url: { url: "data:image/png;base64," + PNG.toString("base64") } }]);
        const count = records.length;
        assert.throws(() => brain.send({ kind: "user", items: [], images: [{ type: "image/gif", item: image }] }),
            { message: "jarvis: brain=image-type" });
        assert.throws(() => brain.send({ kind: "user", items: [], images: [{ type: "image/png", item: speech(kit) }] }),
            { message: "jarvis: brain=image-bytes" });
        assert.throws(() => brain.send({ kind: "user", items: [], images: [{ type: "image/png",
            item: kit.Policy.item(Buffer.alloc(16 * 1024 * 1024), ["screen"]) }] }), { message: "jarvis: brain=request-limit" });
        const custom = open(kit, { base: first + "/text" });
        assert.throws(() => custom.brain.send({ kind: "user", items: [speech(kit)], images: [{ type: "image/png", item: image }] }),
            { message: "jarvis: brain=images-unsupported" });
        assert.equal(records.length, count, "refused images send nothing");
    }

    async function localRows(kit) {
        for (const [id, port] of [["ollama", 11434], ["llama-server", 8080], ["lmstudio", 1234]]) {
            const { brain } = open(kit, { id });
            assert.deepEqual((await drain(brain.send(user(kit)))).events.at(-1), { kind: "done", reason: "stop" }, id);
            assert.deepEqual([last().headers.host, last().url, last().headers.authorization],
                ["127.0.0.1:" + port, "/v1/chat/completions", undefined], id);
        }
    }

    // Cloud origins cannot be served on loopback, so their requests reach a
    // recording door that answers with the text script. The real door and its
    // origin-bound key judge have their own suite.
    const cloud = {
        openai: ["https://api.openai.com/v1/chat/completions", { store: false }],
        openrouter: ["https://openrouter.ai/api/v1/chat/completions", { provider: { data_collection: "deny" } }],
        groq: ["https://api.groq.com/openai/v1/chat/completions", {}],
        cerebras: ["https://api.cerebras.ai/v1/chat/completions", {}],
        mistral: ["https://api.mistral.ai/v1/chat/completions", {}],
        gemini: ["https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", {}]
    };
    async function cloudRows(kit) {
        const store = new kit.Secrets.Secrets(path.join(childEnv.XDG_STATE_HOME, "vgs/jarvis"), childEnv);
        for (const [id, [url, extensions]] of Object.entries(cloud)) {
            const sent = [];
            const wrap = () => ({ request: async (item, options) => {
                sent.push({ item, options });
                const body = fixtures.scripts.text.frames.map(frame => encode(frame, id)).join("");
                return { kind: "response", response: new Response(body, { headers: { "content-type": "text/event-stream" } }), close() {} };
            } });
            const origin = new URL(url).origin;
            const { brain } = open(kit, { id, key: { secrets: store, reference: kit.Secrets.ownReference(id, "fixture", origin) }, wrap });
            assert.deepEqual((await drain(brain.send(user(kit)))).events.at(-1), { kind: "done", reason: "stop" }, id);
            const [{ item, options }] = sent;
            assert.deepEqual([options.url, options.key.origin, options.key.header, options.key.prefix, options.key.value],
                [url, origin, "authorization", "Bearer ", KEY], id);
            const body = JSON.parse(item.content);
            for (const key of ["model", "messages", "stream", "tools"]) delete extensions[key];
            const { model, messages, stream, tools, ...rest } = body;
            assert.deepEqual(rest, extensions, id + " no-store fields");
            pinned("CreateChatCompletionRequest", { model, messages, stream, tools }, id);
        }
    }

    function holding(kit, base) {
        const answers = [];
        const wrap = door => ({ request: async (item, options, grants) => {
            const answer = await door.request(item, options, grants);
            if (answer.kind === "response") {
                const record = { closed: false };
                answers.push(record);
                const close = answer.close;
                answer.close = () => { record.closed = true; close(); };
            }
            return answer;
        } });
        return { ...open(kit, { base, wrap }), answers };
    }
    const clientOf = record => clients.find(client => client.port === record.peer).socket;
    async function cancelHeld(kit) {
        const { brain, answers } = holding(kit, first + "/hold,text");
        const turn = brain.send(user(kit));
        assert.deepEqual(await turn.events.next(), { value: { kind: "text", text: "Thinking" }, done: false });
        const record = last();
        await within(brain.cancel(), "cancel acknowledgement");
        assert.equal(answers[0].closed, true, "the acknowledgement follows the stream's close");
        assert.equal(clientOf(record).destroyed, true, "the acknowledgement follows the socket's close");
        await within(record.closed, "the server sees the stream close");
        await assert.rejects(() => turn.events.next(), { message: "jarvis: brain=cancelled" });
        assert.deepEqual(await turn.events.next(), { value: undefined, done: true });
        assert.equal((await drain(brain.send(user(kit)))).error, null, "the brain is free after cancel");
        assert.deepEqual(last().body.messages.slice(1), [{ role: "user", content: "What time is it?" }], "a cancelled turn leaves no history");
    }
    async function cancelBeforeHeaders(kit) {
        const { brain } = open(kit, { base: first + "/stall" });
        const count = records.length;
        const turn = brain.send(user(kit));
        const pending = assert.rejects(turn.events.next(), { message: "jarvis: brain=cancelled" });
        await within(new Promise(resolve => { const poll = () => records.length > count ? resolve() : setTimeout(poll, 10); poll(); }),
            "the stalled request arrives");
        const record = last();
        await within(brain.cancel(), "cancel acknowledgement");
        await within(record.closed, "the server sees the request close");
        await pending;
    }
    async function breakLoop(kit) {
        const { brain, answers } = holding(kit, first + "/hold");
        for await (const event of brain.send(user(kit)).events) {
            assert.deepEqual(event, { kind: "text", text: "Thinking" });
            break;
        }
        assert.equal(answers[0].closed, true, "return() closes the stream");
        await within(last().closed, "the server sees the stream close");
    }
    // A read that resolves in the same turn as cancel must not finish the
    // turn. A stand-in body makes that order exact; sockets play no part.
    async function cancelRace(kit) {
        let source = null;
        let reading = null;
        const waiting = new Promise(resolve => { reading = resolve; });
        const wrap = door => ({ request: async (item, options, grants) => {
            if (source !== null) return door.request(item, options, grants);
            const body = new ReadableStream({ start(controller) { source = controller; }, pull() { reading(); } }, { highWaterMark: 0 });
            options.signal.addEventListener("abort", () => source.error(new Error("aborted")), { once: true });
            return { kind: "response", response: new Response(body, { headers: { "content-type": "text/event-stream" } }), close() {} };
        } });
        const { brain } = open(kit, { base: first + "/text", wrap });
        const turn = brain.send(user(kit));
        const next = assert.rejects(turn.events.next(), { message: "jarvis: brain=cancelled" });
        await within(waiting, "the driver reads the body");
        source.enqueue(Buffer.from(fixtures.scripts.text.frames.map(frame => encode(frame, "race")).join("")));
        const ack = brain.cancel();
        await within(ack, "cancel acknowledgement");
        await next;
        await drain(brain.send(user(kit, speech(kit, "Again"))));
        assert.deepEqual(last().body.messages.slice(1), [{ role: "user", content: "Again" }], "the cancelled turn left no history");
    }
    // Node's fetch ends a stream in the same turn as its abort. A stand-in
    // body that ends a timer later shows that the acknowledgement waits.
    async function cancelOrder(kit) {
        let reading = null;
        let ended = false;
        const waiting = new Promise(resolve => { reading = resolve; });
        const wrap = () => ({ request: async (item, options) => {
            const body = new ReadableStream({ start(source) {
                options.signal.addEventListener("abort", () => setTimeout(() => { ended = true; source.error(new Error("aborted")); }, 10), { once: true });
            }, pull() { reading(); } }, { highWaterMark: 0 });
            return { kind: "response", response: new Response(body, { headers: { "content-type": "text/event-stream" } }), close() {} };
        } });
        const { brain } = open(kit, { base: first + "/text", wrap });
        const turn = brain.send(user(kit));
        const next = assert.rejects(turn.events.next(), { message: "jarvis: brain=cancelled" });
        await within(waiting, "the driver reads the body");
        await within(brain.cancel(), "cancel acknowledgement");
        assert.equal(ended, true, "the acknowledgement follows the stream's end");
        await next;
    }
    async function cancelUnstarted(kit) {
        let requests = 0;
        const wrap = door => ({ request: (...args) => { requests++; return door.request(...args); } });
        const { brain } = open(kit, { base: first + "/text", wrap });
        await within(brain.cancel(), "idle cancel");
        const turn = brain.send(user(kit));
        assert.throws(() => brain.send(user(kit)), { message: "jarvis: brain=busy" });
        assert.throws(() => brain.start({ instructions: "Again.", tools: [] }), { message: "jarvis: brain=busy" });
        await within(brain.cancel(), "unstarted cancel");
        await assert.rejects(() => turn.events.next(), { message: "jarvis: brain=cancelled" });
        assert.equal(requests, 0, "an unstarted turn reaches no transport");
    }
    async function closeHeld(kit) {
        const { brain, answers } = holding(kit, first + "/hold");
        const turn = brain.send(user(kit));
        await turn.events.next();
        const record = last();
        brain.close();
        await within(record.closed, "the server sees close end the stream");
        await assert.rejects(() => turn.events.next(), { message: "jarvis: brain=cancelled" });
        assert.equal(answers[0].closed, true);
        assert.throws(() => brain.start({ instructions: "Again.", tools: [] }), { message: "jarvis: brain=closed" });
    }

    function starts(kit) {
        const { brain } = open(kit, { base: first + "/text", tools: [] });
        for (const tools of [[{ id: "bad tool", description: "", parameters: {} }],
            [{ id: "a.b", description: "", parameters: {} }, { id: "a_b", description: "", parameters: {} }],
            [{ id: "x".repeat(65), description: "", parameters: {} }], Array(65).fill(TOOLS[0])])
            assert.throws(() => brain.start({ instructions: "Fixture guidance.", tools }),
                { message: tools.length > 64 ? "jarvis: brain=tools" : "jarvis: brain=tool-name" });
        assert.throws(() => brain.start({ instructions: null, tools: [] }), { message: "jarvis: brain=instructions" });
        const fresh = kit.Brain.create({ provider: kit.Providers.select("custom", first), model: "m",
            net: { request() { assert.fail("no request"); } }, recipients: open(kit, { base: first }).recipients, key: null });
        assert.throws(() => fresh.send(user(kit)), { message: "jarvis: brain=not-started" });
        assert.throws(() => fresh.send({ kind: "assistant" }), { message: "jarvis: brain=not-started" });
        brain.start({ instructions: "Fixture guidance.", tools: [] });
        assert.throws(() => brain.send({ kind: "assistant" }), { message: "jarvis: brain=turn" });
        assert.throws(() => brain.send({ kind: "user", items: [] }), { message: "jarvis: brain=turn" });
        assert.throws(() => kit.Brain.create({ provider: { ...kit.Providers.select("openai") }, model: "m", net: null,
            recipients: null, key: null }), { message: "jarvis: provider=row" });
    }
    async function noTools(kit) {
        const { brain } = open(kit, { base: first + "/text", tools: [] });
        await drain(brain.send(user(kit)));
        assert.equal(Object.hasOwn(last().body, "tools"), false, "an empty tool list is not sent");
    }

    try {
        const kit = kitFrom(backend);
        for (const scenario of [textTurns, toolTurns, failedTurnKeepsHistory, keys, release, images, localRows, cloudRows,
            cancelHeld, cancelBeforeHeaders, cancelRace, cancelOrder, breakLoop, cancelUnstarted, closeHeld, starts, noTools]) await scenario(kit);
        for (const [script] of refusals) await refusal(script)(kit);
        assert.deepEqual(faults, [], "every request matched the pinned schema");

        let controls = 0;
        async function control(name, needle, replacement, check, target = file) {
            await mutant(target, name, needle, replacement, async (_module, folder) => check(kitFrom(folder)), "OpenAIChat.js");
            controls++;
        }
        const plain = [
            // The plan's control: a dropped tool-call chunk must never yield a partial call.
            ["dropped-tool-call-chunk", 'try { parsed = JSON.parse(call.arguments); } catch { fail("tool-call-arguments"); }',
                "try { parsed = JSON.parse(call.arguments); } catch { parsed = {}; }", refusal("tool-call-lost-middle")],
            ["tool-call-start", 'fail("tool-call-start");', "void 0;", refusal("tool-call-lost-start")],
            ["tool-call-index", 'if (fragment.index > calls.length) fail("tool-call-index");', "", refusal("tool-call-lost-call")],
            ["tool-call-conflict", 'fail("tool-call-conflict");', "void 0;", refusal("tool-call-conflict")],
            ["tool-call-id", 'if (new Set(calls.map(call => call.id)).size !== calls.length) fail("tool-call-id");', "", refusal("tool-call-duplicate-id")],
            ["tool-call-name", 'if (!names.has(call.name)) fail("tool-call-name");', "", refusal("tool-call-unknown")],
            ["tool-call-object", 'if (!plain(parsed)) fail("tool-call-arguments");', "", refusal("tool-call-array")],
            ["tool-call-limit", 'if (calls.length === TOOL_CALLS) fail("tool-call-limit");', "", refusal("tool-call-limit")],
            ["tool-id-mapping", "tool: names.get(call.name)", "tool: call.name", toolTurns],
            ["stop-with-calls", 'if (count !== 0) fail("finish reason=stop-with-tool-calls");', "", refusal("stop-with-tool-calls")],
            ["tools-without-call", 'if (count === 0) fail("finish reason=tool-calls-without-call");', "", refusal("tool-calls-without-call")],
            ["finish-length", 'case "length": return fail("finish reason=length");', 'case "length": return "stop";', refusal("finish-length")],
            ["finish-filter", 'case "content_filter": return fail("finish reason=content-filter");', 'case "content_filter": return "stop";', refusal("finish-content-filter")],
            ["finish-function", 'case "function_call": return fail("finish reason=function-call");', 'case "function_call": return "stop";', refusal("finish-function-call")],
            ["finish-missing", 'case null: return fail("finish-missing");', 'case null: return "stop";', refusal("finish-missing")],
            ["finish-unknown", "default: return fail(\"chunk-shape\");\n    }\n}", "default: return \"stop\";\n    }\n}", refusal("malformed-finish-unknown")],
            ["chunk-order", 'if (finish !== null) fail("chunk-order");', "", refusal("chunk-after-finish")],
            ["refusal", 'if (typeof refusal === "string" && refusal !== "") fail("refusal");', "", refusal("refusal")],
            ["stream-error", 'if (Object.hasOwn(value, "error")) fail("stream-error");', "", refusal("stream-error")],
            ["stream-truncated", 'if (read.done) fail("stream-truncated");', 'if (read.done) { settle({ kind: "done" }); return; }', refusal("truncated")],
            ["chunk-json", 'try { value = JSON.parse(data); } catch { fail("chunk-json"); }', "value = JSON.parse(data);", refusal("malformed-not-json")],
            ["chunk-object", 'if (!plain(value)) fail("chunk-shape");', "", refusal("malformed-not-object")],
            ["choices", "value.choices.length > 1", "false", refusal("malformed-two-choices")],
            ["choice-index", "choice.index !== 0 ||", "", refusal("malformed-choice-index")],
            ["content-type", "(content !== null && !optionalString(content)) ||", "", refusal("malformed-content-type")],
            ["finish-type", "|| (finish !== null && !optionalString(finish))", "", refusal("malformed-finish-type")],
            ["fragment-index", "&& fragment.index >= 0", "", refusal("malformed-fragment-index")],
            ["fragment-type", '&& (fragment.type === undefined || fragment.type === "function")', "", refusal("malformed-fragment-type")],
            ["event-type", 'if (event.event !== "message") fail("chunk-shape");', "", refusal("malformed-event-type")],
            ["sse-total", "total: 8 * 1024 * 1024", "total: 16 * 1024 * 1024", refusal("total-limit")],
            ["sse-line", "line: 1024 * 1024", "line: 2 * 1024 * 1024", refusal("line-limit")],
            ["content-type-header", 'fail("content-type");', "void 0;", refusal("not-sse")],
            ["status-table", '429: "rate-limited"', '429: "provider-error"', refusal("http-429")],
            ["error-body", "await response.body?.cancel();", 'const detail = await response.text(); if (detail) fail("http " + detail);', refusal("http-401")],
            ["history", 'history.push(entry, { role: "assistant"', 'void ({ role: "assistant"', textTurns],
            ["read-after-cancel", 'if (controller.signal.aborted) fail("cancelled");\n                    if (read.done)', "if (read.done)", cancelRace],
            ["no-key", 'if (key === null && provider.key === "required") fail("no-key");', "", keys],
            ["key-first-need", "let secret = null;", "let secret = key === null ? null : key.secrets.lookup(key.reference);", keys],
            ["key-zero", "if (secret !== null) secret.fill(0);", "", keys],
            ["key-scheme", 'prefix: "Bearer "', 'prefix: "Token "', keys],
            ["no-store", "...provider.noStore", "...{}", cloudRows],
            ["release-marker", "            return decision;\n        }", "            return decision.kind === \"send\" ? decision : { ...decision, content: item.content };\n        }", release],
            ["release-labels", "sent.flatMap(item => item.labels)", "entries.flatMap(entry => (entry.items ?? []).flatMap(item => item.labels))", release],
            ["history-release", 'if (released(entry.item).kind !== "send") fail("history-release");', "released(entry.item);", release],
            ["release-empty", 'if (labels.length === 0) fail("release-empty");', "", release],
            ["images-unsupported", 'if (images.length !== 0 && !provider.images) fail("images-unsupported");', "", images],
            ["image-type", '!IMAGE_TYPES.includes(image.type)', "false", images],
            ["image-bytes", '!(image.item.content instanceof Uint8Array)', "false", images],
            ["request-limit", 'if (Buffer.byteLength(body) > REQUEST_BYTES) fail("request-limit");', "", images],
            ["image-part", '"data:" + image.type + ";base64,"', '"data:image/png,"', images],
            ["tool-results", "!calls.every(call => byId.has(call.id))", "false", toolTurns],
            ["tool-results-pending", 'if (pending().length !== 0) fail("tool-results-pending");', "", toolTurns],
            ["item-text", 'if (!item || typeof item.content !== "string") fail("item-text");', "", toolTurns],
            ["tool-name-pattern", "!NAME.test(name) || ", "", starts],
            ["tool-name-unique", " || names.has(name)", "", starts],
            ["tools-bound", 'if (value.tools.length > TOOLS) fail("tools");', "", starts],
            ["busy", 'if (active !== null) fail("busy");', "", cancelUnstarted],
            ["empty-tools", "context.tools.length === 0 ? {} : ", "false ? {} : ", noTools],
            ["cancel-ack", "            return finished;\n        } };", "            return Promise.resolve();\n        } };", cancelOrder],
            ["cancel-abort", "            controller.abort();\n            if (!started) {", "            if (!started) {", cancelHeld],
            ["unstarted-cancel", "                started = true;\n                result =", "                result =", cancelUnstarted],
            ["close-cancels", "if (active !== null) active.cancel();", "", closeHeld],
            ["return-cancels", "await current.cancel();", "", breakLoop]
        ];
        for (const [name, needle, replacement, check] of plain) await control(name, needle, replacement, check);
        console.log("test-jarvis-brain-openai: ok scripts=" + Object.keys(fixtures.scripts).length + " refusals=" + refusals.length
            + " requests=" + records.length + " controls=" + controls);
    } finally {
        for (const door of doors) door.close();
        sockets.Socket.prototype.connect = originalConnect;
        for (const record of records) record.socket.destroy();
        await Promise.all(listeners.map(({ instance }) => new Promise(resolve => instance.close(resolve))));
    }
}, standins)?.catch(error => { console.error(error); process.exitCode = 1; });
