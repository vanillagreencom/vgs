#!/usr/bin/env node
// Minimal API fixtures from the provider references in jarvis-accounts.md.
// Authored 2026-09-30. fetch is the external stand-in, not Accounts logic.
"use strict";
const { assert, fs, path, tree, environment, world, mutant } = require("./fixtures/jarvis/accounts-world.js");
const http = require("node:http");
const plugin = path.join(tree, "shell/plugins/vgs.jarvis");
const privateKey = "fixture-secret-private";
const chat = { choices: [{ message: { role: "assistant", content: "OK" }, finish_reason: "length" }],
    usage: { completion_tokens: 1 } };
const messages = { type: "message", role: "assistant", content: [{ type: "text", text: "OK" }], usage: { output_tokens: 1 } };

world(async () => {
    const env = environment();
    const directory = path.join(env.XDG_STATE_HOME, "vgs/jarvis");
    const { Secrets } = require(path.join(plugin, "backend/Secrets.js"));
    const store = new Secrets(directory, env);
    const originalFetch = global.fetch;
    let calls = [], attempts = 0, payload = chat, httpStatus = 200;
    const callLog = () => fs.existsSync(path.join(env.XDG_STATE_HOME, "secret-calls"))
        ? fs.readFileSync(path.join(env.XDG_STATE_HOME, "secret-calls"), "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : [];
    const standin = async (url, options) => {
        attempts++;
        const rows = fs.readdirSync(path.join(directory, "audit")).filter(name => name.endsWith(".jsonl"));
        assert.ok(rows.length > 0, "audit must exist before fetch");
        const audit = rows.flatMap(name => fs.readFileSync(path.join(directory, "audit", name), "utf8").trim().split("\n").map(JSON.parse));
        assert.equal(audit.at(-1).outcome, "pending");
        assert.equal(audit.at(-1).decision, "send");
        const headers = new Headers(options.headers);
        calls.push({ url, method: options.method, body: JSON.parse(options.body), headers });
        assert.equal(options.redirect, "manual", "the network door owns redirect refusal");
        return new Response(typeof payload === "string" ? payload : JSON.stringify(payload), { status: httpStatus });
    };
    global.fetch = standin;
    let cases = 0, controls = 0;

    function account(folder, provider = "openai", origin = "https://api.openai.com") {
        store.remember({ provider, account: "verification", origin, attributes: { application: "fixture", provider } });
        const Judge = require(path.join(folder, "backend/Accounts.js")).Accounts;
        const judge = new Judge(directory, env);
        const before = calls.length, lookedUp = callLog().length;
        const selected = judge.discover().find(item => item.source.kind === "keyring" && item.provider === provider
            && item.source.reference.origin === origin);
        assert.ok(selected);
        assert.equal(calls.length, before, "discovery makes no inference request");
        assert.equal(callLog().length, lookedUp, "discovery never reads a key");
        return { judge, id: selected.id };
    }
    async function verified(folder, provider = "openai", origin = "https://api.openai.com", model = "") {
        const { judge, id } = account(folder, provider, origin);
        const before = calls.length;
        assert.deepEqual(await judge.verify(id, "user", undefined, model), { kind: "verified" });
        assert.equal(calls.length, before + 1, "one inference request");
        assert.equal(judge.accounts.find(item => item.id === id).state.kind, "verified");
        assert.equal(JSON.stringify(judge.status()).includes(privateKey), false);
        return calls.at(-1);
    }
    try {
        for (const [provider, route, model, limit] of [
            ["openai", "/v1/chat/completions", "", "max_completion_tokens"],
            ["openrouter", "/api/v1/chat/completions", "", "max_tokens"],
            ["groq", "/openai/v1/chat/completions", "", "max_tokens"],
            ["cerebras", "/v1/chat/completions", "fixture-model", "max_completion_tokens"],
            ["mistral", "/v1/chat/completions", "", "max_tokens"],
            ["gemini", "/v1beta/openai/chat/completions", "", "max_tokens"]
        ]) {
            payload = chat;
            const request = await verified(plugin, provider, "https://fixture.invalid", model);
            assert.equal(request.url, "https://fixture.invalid" + route);
            assert.deepEqual(request.body.messages, [{ role: "user", content: "Reply OK." }]);
            assert.equal(request.body[limit], 1);
            assert.equal(request.body.stream, false);
            assert.equal(request.headers.get("authorization"), "Bearer " + privateKey);
            cases++;
        }
        payload = messages;
        const anthropic = await verified(plugin, "anthropic", "https://fixture.invalid");
        assert.equal(anthropic.url, "https://fixture.invalid/v1/messages");
        assert.equal(anthropic.body.max_tokens, 1);
        assert.equal(anthropic.headers.get("x-api-key"), privateKey);
        assert.equal(anthropic.headers.get("anthropic-version"), "2023-06-01");
        cases++;
        payload = chat;

        for (const [value, status, reason] of [
            [{ models: ["fixture"] }, 200, "no-inference"],
            [{ choices: [{ message: { role: "assistant", content: "" } }] }, 200, "no-inference"],
            ["not-json", 200, "reply-json"], [{ ...chat, padding: "x".repeat(65537) }, 200, "reply-limit"],
            [chat, 401, "http-401"], [chat, 302, "network-redirect"]
        ]) {
            payload = value; httpStatus = status;
            const { judge, id } = account(plugin);
            assert.deepEqual(await judge.verify(id, "user"), { kind: "unavailable", reason });
            cases++;
        }
        payload = chat; httpStatus = 200;
        const neededModel = async folder => {
            const pair = account(folder, "cerebras");
            const count = attempts;
            assert.deepEqual(await pair.judge.verify(pair.id, "user"), { kind: "unavailable", reason: "model-required" });
            assert.equal(attempts, count);
        };
        await neededModel(plugin);
        await mutant("backend/Accounts.js", "verify-model-required",
            'if (row.probe.driver !== "llama" && !model) fail("verify=model-required");',
            'if (false) fail("verify=model-required");', neededModel);
        controls++; cases++;
        const { judge, id } = account(plugin);
        const before = calls.length;
        await assert.rejects(() => judge.verify(id, "automatic"), /explicit-user-required/);
        assert.equal(calls.length, before);
        assert.equal((await judge.verify(id, "user", undefined, "bad\nmodel")).reason, "model-invalid");
        assert.equal(calls.length, before);
        cases++;

        const badOrigin = async folder => {
            const pair = account(folder, "openai", "http://localhost:11434");
            const count = attempts;
            assert.deepEqual(await pair.judge.verify(pair.id, "user"),
                { kind: "unavailable", reason: "network-key-origin" });
            assert.equal(attempts, count, "an origin mismatch cannot start fetch");
        };
        await badOrigin(plugin);
        await mutant("backend/Accounts.js", "verify-key-origin", "key = { origin: ref.origin, value",
            "key = { origin: target.origin, value", badOrigin);
        controls++; cases++;

        const doorUse = async folder => {
            const net = require(path.join(folder, "backend/net.js"));
            const create = net.create;
            let used = 0;
            net.create = selected => {
                const door = create(selected);
                return { ...door, request(...args) { used++; return door.request(...args); } };
            };
            try { await verified(folder); assert.equal(used, 1, "verification must use the network door"); }
            finally { net.create = create; }
        };
        await doorUse(plugin);
        const requestLine = "response = await start(() => door.request(item, { url: target.url, headers, key, signal }, grants));";
        await mutant("backend/Accounts.js", "verify-door-bypass", requestLine,
            'response = await start(() => fetch(target.url, { method: "POST", headers: { ...headers, [key.header]: key.prefix + key.value }, body: item.content, redirect: "manual", signal }).then(response => ({ kind: "response", response, close() {} })));',
            doorUse);
        controls++;

        const unavailableAudit = async folder => {
            const pair = account(folder);
            const saved = path.join(directory, "audit-saved");
            fs.renameSync(path.join(directory, "audit"), saved);
            fs.writeFileSync(path.join(directory, "audit"), "not-a-directory");
            const count = attempts;
            try {
                assert.equal((await pair.judge.verify(pair.id, "user")).reason, "audit-unavailable");
                assert.equal(attempts, count, "audit refusal prevents a request");
            } finally {
                fs.unlinkSync(path.join(directory, "audit"));
                fs.renameSync(saved, path.join(directory, "audit"));
            }
        };
        await unavailableAudit(plugin);
        const auditNeedle = "const started = audit.before(event, send);";
        await mutant("backend/Accounts.js", "verify-audit-bypass", auditNeedle,
            "const started = { kind: \"started\", value: send() };",
            unavailableAudit);
        controls++; cases++;

        await mutant("backend/Accounts.js", "verify-release-grant", 'const grants = [{ recipients: selected, labels: ["command"] }];',
            "const grants = [];", folder => verified(folder));
        controls++;
        await mutant("backend/Accounts.js", "verify-inference-proof",
            'fail("verify=no-inference");\n            const saved',
            'void 0;\n            const saved', async folder => {
                payload = { choices: [{ message: { role: "assistant", content: "" } }] };
                try {
                    const pair = account(folder);
                    assert.equal((await pair.judge.verify(pair.id, "user")).reason, "no-inference");
                } finally { payload = chat; }
            });
        controls++;
        const replyLimit = async folder => {
            payload = { ...chat, padding: "x".repeat(65537) };
            try {
                const pair = account(folder);
                assert.equal((await pair.judge.verify(pair.id, "user")).reason, "reply-limit");
            } finally { payload = chat; }
        };
        await replyLimit(plugin);
        await mutant("backend/Accounts.js", "verify-reply-bound", "if (size > MAX_BYTES)",
            "if (false)", replyLimit);
        controls++;
        const clearedKey = async folder => {
            const pair = account(folder);
            const lookup = pair.judge.secrets.lookup.bind(pair.judge.secrets);
            let bytes;
            pair.judge.secrets.lookup = ref => { bytes = lookup(ref); return bytes; };
            assert.deepEqual(await pair.judge.verify(pair.id, "user"), { kind: "verified" });
            assert.ok(bytes.every(value => value === 0), "the retrieved key Buffer is cleared");
        };
        await clearedKey(plugin);
        await mutant("backend/Accounts.js", "verify-clear-key", "keyBytes?.fill(0);",
            "void keyBytes;", clearedKey);
        controls++;

        const noDiscoveryRequest = async folder => {
            const before = calls.length;
            account(folder);
            await new Promise(resolve => setImmediate(resolve)); // Complete any mistakenly started async request.
            assert.equal(calls.length, before);
        };
        await noDiscoveryRequest(plugin);
        await mutant("backend/Accounts.js", "verify-during-discovery", "this.accounts = result;\n        return this.accounts;",
            'this.accounts = result;\n        void this.verify(result.find(item => item.source.kind === "keyring").id, "user");\n        return this.accounts;',
            noDiscoveryRequest);
        controls++;

        global.fetch = undefined;
        await assert.rejects(() => verified(plugin), assert.AssertionError,
            "removing the fetch stand-in breaks verification without host fallback");
        global.fetch = standin;
        cases++;
        // Real loopback HTTP uses the real network door. These listeners live
        // only in J09's private namespace and never expose a host model.
        const servers = [];
        const localCalls = [];
        try {
            for (const [port, expectedPath, reply] of [
                [11434, "/api/generate", { done: true, response: "OK", eval_count: 1 }],
                [8080, "/completion", { content: "OK", tokens_predicted: 1 }],
                [1234, "/v1/chat/completions", chat]
            ]) {
                const server = http.createServer((req, res) => {
                    let text = "";
                    req.on("data", chunk => { text += chunk; });
                    req.on("end", () => {
                        localCalls.push({ port, url: req.url, body: JSON.parse(text), headers: req.headers });
                        assert.equal(req.url, expectedPath);
                        res.writeHead(200, { "content-type": "application/json" });
                        res.end(JSON.stringify(reply));
                    });
                });
                servers.push(server);
                await new Promise((resolve, reject) => {
                    server.once("error", reject);
                    server.listen(port, "127.0.0.1", resolve);
                });
            }
            global.fetch = originalFetch;
            for (const [provider, model, tokens] of [
                ["ollama", "fixture-model", "num_predict"], ["llama-server", "", "n_predict"], ["lm-studio", "fixture-model", "max_tokens"]
            ]) {
                const Judge = require(path.join(plugin, "backend/Accounts.js")).Accounts;
                const judge = new Judge(directory, env);
                const selected = judge.discover().find(item => item.source.kind === "local" && item.provider === provider);
                const before = localCalls.length;
                assert.deepEqual(await judge.verify(selected.id, "user", undefined, model), { kind: "verified" });
                assert.equal(localCalls.length, before + 1);
                const request = localCalls.at(-1);
                assert.equal(request.body.options?.[tokens] ?? request.body[tokens], 1);
                assert.equal(request.headers.authorization, undefined);
                cases++;
            }
        } finally {
            global.fetch = standin;
            for (const server of servers) {
                server.closeAllConnections();
                await new Promise(resolve => server.close(resolve));
            }
        }
        const verifiedAudit = fs.readdirSync(path.join(directory, "audit")).filter(name => name.endsWith(".jsonl"))
            .map(name => fs.readFileSync(path.join(directory, "audit", name), "utf8")).join("");
        assert.equal(verifiedAudit.includes(privateKey), false);
        for (const call of callLog()) {
            assert.equal(call.args[0], "lookup");
            assert.equal(JSON.stringify(call).includes(privateKey), false);
            assert.equal(call.env.OPENAI_API_KEY, undefined);
        }
        console.log("test-jarvis-account-verify: ok cases=" + cases + " controls=" + controls);
    } finally { global.fetch = originalFetch; }
});
