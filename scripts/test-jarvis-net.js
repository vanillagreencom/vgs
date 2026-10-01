#!/usr/bin/env node
// Synthetic HTTP endpoints and RFC 6455 section 5 frames, 2026-09-30.
// All traffic, including the synthetic non-loopback address, stays in J09.
"use strict";
const { assert, fs, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const { standins } = require("./fixtures/jarvis/keys-world.js");
const http = require("node:http");
const sockets = require("node:net");
const cp = require("node:child_process");
const { createHash } = require("node:crypto");
const { once } = require("node:events");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/net.js");
const Net = require(file);
const Policy = require("../shell/plugins/vgs.jarvis/backend/Policy.js");

world(async () => {
    const ip = cp.spawnSync(path.join(process.env.JARVIS_TEST_ROOT, "bootstrap/ip"),
        ["addr", "add", "192.0.2.1/32", "dev", "lo"],
        { env: { PATH: process.env.PATH }, encoding: "utf8" });
    assert.equal(ip.error, undefined);
    assert.equal(ip.status, 0, ip.stderr);
    const connections = [];
    const originalConnect = sockets.Socket.prototype.connect;
    // Observe the real socket creator, never replace the transport under test.
    sockets.Socket.prototype.connect = function (...args) {
        const options = Array.isArray(args[0]) ? args[0][0] : args[0];
        assert.equal(typeof options, "object", "socket observer must recognize Undici's connect options");
        connections.push(options.host);
        return Reflect.apply(originalConnect, this, args);
    };
    const records = [], frames = [], peers = new Set(), owners = [];
    let second;
    function server(host) {
        const instance = http.createServer(async (request, response) => {
            const chunks = [];
            for await (const chunk of request) chunks.push(chunk);
            records.push({ host, url: request.url, headers: request.headers, body: Buffer.concat(chunks).toString() });
            if (request.url.startsWith("/redirect/")) {
                const [, , status, destination] = request.url.split("/");
                response.writeHead(Number(status), { Location: destination === "same" ? "/echo" : second + "/echo" });
                response.end();
            } else if (request.url === "/stream") {
                response.writeHead(200, { "Content-Type": "text/event-stream" });
                response.write("data: pending\n\n");
            } else { response.writeHead(200); response.end("fixture"); }
        });
        instance.on("connection", socket => { peers.add(socket); socket.on("close", () => peers.delete(socket)); });
        instance.on("upgrade", (request, socket) => {
            records.push({ host, url: request.url, headers: request.headers, body: "" });
            if (request.url === "/redirect-ws") {
                socket.end("HTTP/1.1 307 Temporary Redirect\r\nLocation: " + second + "/echo\r\nContent-Length: 0\r\n\r\n");
                return;
            }
            const accept = createHash("sha1").update(request.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
            socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
            // A fixed server message proves the channel does not expose the
            // native socket through event.target. Only fixture frames are read.
            socket.write(Buffer.concat([Buffer.from([0x81, 7]), Buffer.from("fixture")]));
            let pending = Buffer.alloc(0);
            let sentClose = false;
            socket.on("data", chunk => {
                pending = Buffer.concat([pending, chunk]);
                while (pending.length >= 6) {
                    const opcode = pending[0] & 15;
                    const length = pending[1] & 127;
                    assert.ok(length < 126 && (pending[1] & 128) !== 0, "bounded, masked fixture frame");
                    if (pending.length < 6 + length) return;
                    const mask = pending.subarray(2, 6);
                    const payload = Buffer.from(pending.subarray(6, 6 + length));
                    payload.forEach((byte, index) => { payload[index] = byte ^ mask[index % 4]; });
                    pending = pending.subarray(6 + length);
                    if (opcode === 8) {
                        socket.end(sentClose ? undefined : Buffer.concat([Buffer.from([0x88, payload.length]), payload]));
                        return;
                    }
                    assert.ok(opcode === 1 || opcode === 2, "fixture expects text or binary frames");
                    if (request.url === "/close-abrupt") { socket.destroy(); return; }
                    if (request.url === "/close-normal" || request.url === "/close-policy") {
                        const reason = Buffer.from("fixture-private-provider-reason");
                        const closed = Buffer.alloc(2 + reason.length);
                        closed.writeUInt16BE(request.url === "/close-normal" ? 1000 : 1008);
                        reason.copy(closed, 2);
                        sentClose = true;
                        socket.write(Buffer.concat([Buffer.from([0x88, closed.length]), closed]));
                        continue;
                    }
                    frames.push(payload.toString());
                    socket.write(Buffer.concat([Buffer.from([0x80 | opcode, payload.length]), payload]));
                }
            });
        });
        return instance;
    }
    const hosts = ["127.0.0.1", "127.0.0.1", "192.0.2.1", "192.0.2.1"];
    const servers = hosts.map(server);
    await Promise.all(servers.map((instance, index) => new Promise((resolve, reject) => {
        instance.once("error", reject);
        instance.listen(0, hosts[index], resolve);
    })));
    const first = "http://127.0.0.1:" + servers[0].address().port;
    second = "http://127.0.0.1:" + servers[1].address().port;
    const remote = "http://192.0.2.1:" + servers[2].address().port;
    // A separate listener has no pooled connection. The offline control must
    // reach a new socket, not merely reuse an earlier cloud-test connection.
    const offlineTarget = "http://192.0.2.1:" + servers[3].address().port;
    const local = { kind: "local", provider: "local", account: "" };
    function selected(logic = Policy, brain = first, voice = second, profile = "standard", cloudVision = "ask") {
        return logic.recipients({ conversation: "fixture", profile, cloudVision,
            brain: { kind: "network", provider: "brain", account: "fixture", origin: brain },
            speech: voice === null ? [local] : [{ kind: "network", provider: "voice", account: "fixture", origin: voice }] });
    }
    function owner(net = Net, policy = Policy, brain = first, voice = second, profile = "standard", cloudVision = "ask") {
        const recipients = selected(policy, brain, voice, profile, cloudVision);
        const door = net.create(recipients);
        owners.push(door);
        return { recipients, door };
    }
    const speech = Policy.item("fixture speech", ["speech"]);
    const fileText = Policy.item("PRIVATE file", ["file"]);
    const screen = Policy.item("PRIVATE image", ["screen"]);
    const key = { origin: first, header: "authorization", prefix: "Bearer ", value: "synthetic-key" };
    async function consume(door, item, options, grants = []) {
        const answer = await door.request(item, options, grants);
        if (answer.kind !== "response") return answer;
        try { assert.equal(await answer.response.text(), "fixture"); }
        finally { answer.close(); }
        return answer;
    }
    const childEnv = {};
    for (const name of ["PATH", "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
        "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]) childEnv[name] = process.env[name];
    const { Secrets, ownReference } = require("../shell/plugins/vgs.jarvis/backend/Secrets.js");
    function storedLocalKey(folder = path.join(tree, "shell/plugins/vgs.jarvis")) {
        const entered = first.replace("127.0.0.1", "localhost");
        const added = cp.spawnSync("python3", [path.join(tree, "scripts/fixtures/jarvis/key-tui.py"),
            path.join(tree, "shell/plugins/vgs.jarvis/tui/add-key.sh"), path.join(tree, "bin/lib/tui.sh"),
            folder, "--origin", entered], { env: childEnv, encoding: "utf8", timeout: 15000 });
        assert.equal(added.error, undefined);
        assert.equal(added.status, 0, added.stdout + added.stderr);
        assert.match(added.stdout, /jarvis-keys: stored=libsecret/);
        assert.equal((added.stdout + added.stderr).includes("test-key-must-stay-private"), false);
        const store = new Secrets(path.join(childEnv.XDG_STATE_HOME, "vgs/jarvis"), childEnv);
        const reference = store.references().find(value => value.provider === "fixture" && value.account === "test"
            && value.origin === first);
        assert.ok(reference, "real Add key must store the selected numeric origin");
        assert.equal(reference.attributes.origin, first);
        const calls = fs.readFileSync(path.join(childEnv.XDG_STATE_HOME, "secret-calls"), "utf8").trim().split("\n").map(JSON.parse);
        const receipt = calls.findLast(value => value.argv[0] === "store");
        assert.equal(receipt.argv[receipt.argv.indexOf("origin") + 1], first);
        return { store, reference, entered };
    }
    async function closeOutcome(net, policy, route, code, wasClean) {
        const { door } = owner(net, policy);
        const channel = door.websocket(speech, { url: first.replace("http:", "ws:") + route });
        const greeting = once(channel.events, "message");
        await once(channel.events, "open");
        await greeting;
        const closing = once(channel.events, "close");
        channel.send(speech);
        const [event] = await closing;
        assert.deepEqual([event.code, event.wasClean], [code, wasClean], route);
        assert.equal(event.reason, undefined, "raw provider reason stays private");
        assert.equal(event.target, channel.events);
        assert.equal(event.target.send, undefined, "close event cannot expose the native socket");
    }
    async function safeHeaderError(net, policy, value) {
        const { door } = owner(net, policy);
        const bad = { ...key, value };
        const check = error => {
            assert.equal(error.message, "jarvis: net=key-shape");
            assert.equal(error.cause, undefined);
            assert.equal(String(error.stack).includes("fixture-private-key"), false);
            return true;
        };
        const count = connections.length;
        await assert.rejects(() => door.request(speech, { url: first, key: bad }), check);
        assert.throws(() => door.websocket(speech, { url: first.replace("http:", "ws:"), key: bad }), check);
        assert.equal(connections.length, count, "malformed credentials open no socket");
    }
    try {
        const { door } = owner();
        await consume(door, speech, { url: first + "/echo", key });
        assert.equal(records.at(-1).headers.authorization, "Bearer synthetic-key");
        assert.equal(records.at(-1).body, "fixture speech");
        assert.ok(connections.includes("127.0.0.1"), "observer saw a real socket");
        // The same rule refuses a request's key and, before any lookup,
        // a key the brain driver could never send.
        const refuseKey = (net, policy) => {
            const { door } = owner(net, policy);
            assert.throws(() => net.assertKeyTarget(second + "/v1", key.origin), { message: "jarvis: net=key-origin" });
            return assert.rejects(() => consume(door, speech, { url: second + "/echo", key }),
                { message: "jarvis: net=key-origin" });
        };
        const refusePlaintext = async (net, policy) => {
            const { door } = owner(net, policy, remote, null);
            assert.throws(() => net.assertKeyTarget(remote + "/v1", remote), { message: "jarvis: net=key-plaintext" });
            await assert.rejects(() => consume(door, speech, { url: remote, key: { ...key, origin: remote } }),
                { message: "jarvis: net=key-plaintext" });
        };
        assert.equal(Net.assertKeyTarget(first + "/v1", key.origin), undefined, "a key may travel to its own origin");
        await refuseKey(Net, Policy);
        await refusePlaintext(Net, Policy);
        await consume(door, speech, { url: second + "/echo" });
        assert.equal(records.at(-1).headers.authorization, undefined, "the second origin has no borrowed key");
        await consume(door, Policy.item("", ["speech"]), { url: first + "/echo", method: "GET" });
        assert.equal(records.at(-1).body, "");
        await assert.rejects(() => consume(door, speech, { url: first + "/echo", method: "GET" }),
            { message: "jarvis: net=body-method" });
        for (const header of ["authorization", "x-api-key", "xi-api-key"]) {
            await consume(door, speech, { url: first + "/echo", key: { ...key, header, prefix: "" } });
            assert.equal(records.at(-1).headers[header], "synthetic-key");
        }
        for (const status of [301, 302, 303, 307, 308])
            for (const destination of ["same", "other"]) {
                const count = records.length;
                await assert.rejects(() => consume(door, speech, { url: first + "/redirect/" + status + "/" + destination, key }),
                    { message: "jarvis: net=redirect" });
                assert.equal(records.length, count + 1, "redirect makes no second request");
                assert.equal(records.at(-1).headers.authorization, "Bearer synthetic-key");
            }

        const cloud = owner(Net, Policy, remote, null);
        const start = connections.length;
        assert.equal((await consume(cloud.door, fileText, { url: remote + "/echo" })).kind, "ask");
        assert.equal(connections.length, start, "ungranted file opens no socket");
        assert.equal((await consume(cloud.door, screen, { url: remote + "/echo" })).kind, "ask");
        await consume(cloud.door, fileText, { url: remote + "/echo" },
            [{ recipients: cloud.recipients, labels: ["file"] }]);
        assert.equal(records.at(-1).body, "PRIVATE file");
        const never = owner(Net, Policy, remote, null, "trusted", "never");
        const withheld = await consume(never.door, screen, { url: remote + "/echo" });
        assert.equal(withheld.kind, "withhold");
        assert.equal(withheld.content, "[withheld: screen content]");
        assert.equal(JSON.stringify(withheld).includes("PRIVATE"), false);

        const offline = owner(Net, Policy, first, null);
        const before = connections.length;
        await assert.rejects(() => consume(offline.door, speech, { url: offlineTarget + "/echo" }),
            { message: "jarvis: net=offline-recipient" });
        assert.throws(() => offline.door.websocket(speech, { url: offlineTarget.replace("http:", "ws:") + "/echo" }),
            { message: "jarvis: net=offline-recipient" });
        assert.equal(connections.length, before, "offline refuses before socket creation");
        const localhost = first.replace("127.0.0.1", "localhost");
        const pinned = owner(Net, Policy, Net.endpoint(localhost).origin, null);
        await consume(pinned.door, speech, { url: localhost + "/echo", key });
        assert.equal(records.at(-1).headers.host, new URL(first).host);
        assert.equal(Net.endpoint(localhost).url, first + "/", "localhost never needs DNS");
        await assert.rejects(() => consume(pinned.door, speech, { url: localhost, key: { ...key, origin: localhost } }),
            { message: "jarvis: net=key-origin" });
        const added = storedLocalKey();
        const lookedUp = added.store.lookup(added.reference);
        try {
            const storedKey = { ...key, origin: added.reference.origin, value: lookedUp.toString() };
            await consume(pinned.door, speech, { url: added.entered + "/echo", key: storedKey });
            assert.equal(records.at(-1).headers.authorization, "Bearer test-key-must-stay-private");
            const previouslyBound = ownReference("fixture", "existing", added.entered);
            assert.equal(previouslyBound.origin, added.entered, "existing references are not migrated");
            await assert.rejects(() => consume(pinned.door, speech,
                { url: added.entered, key: { ...storedKey, origin: previouslyBound.origin } }),
                { message: "jarvis: net=key-origin" });
        } finally { lookedUp.fill(0); }

        const urls = [
            ["http://127.1", "http://127.0.0.1", true],
            ["http://2130706433", "http://127.0.0.1", true],
            ["http://localhost", "http://127.0.0.1", true],
            ["http://[::1]:9000", "http://[::1]:9000", true],
            ["http://[::ffff:127.0.0.1]", "http://[::ffff:7f00:1]", true],
            ["https://EXAMPLE.test:443/path", "https://example.test", false],
            ["wss://example.test:443/path", "https://example.test", false],
            ["http://localhost.evil.test", "http://localhost.evil.test", false],
            ["http://127.0.0.1.evil.test", "http://127.0.0.1.evil.test", false],
            ["http://0.0.0.0", "http://0.0.0.0", false]
        ];
        for (const [value, origin, loopback] of urls)
            assert.deepEqual([Net.endpoint(value).origin, Net.endpoint(value).loopback], [origin, loopback]);
        for (const value of ["file:///tmp/file", "http://user:pass@127.0.0.1", first + "/#secret", first + "/#", {}, "not a URL"])
            assert.throws(() => Net.endpoint(value), { message: "jarvis: net=url" });
        for (const headers of [{ Authorization: "unbound" }, { Cookie: "unbound" }, { Host: "other.example" }, { "X-Api-Key": "unbound" }])
            await assert.rejects(() => consume(door, speech, { url: first, headers }), { message: "jarvis: net=header" });
        await consume(door, speech, { url: first, headers: { "Content-Type": "application/json", "OpenAI-Beta": "fixture" } });
        assert.equal(records.at(-1).headers["openai-beta"], "fixture");
        const badKeys = [
            [{ ...key, origin: first + "/" }, "key-origin"],
            [{ ...key, header: "host" }, "key-shape"],
            [{ ...key, value: "" }, "key-shape"],
            [{ ...key, value: "key\r\nextra" }, "key-shape"],
            [{ ...key, prefix: undefined }, "key-shape"],
            [{ ...key, prefix: "\n" }, "key-shape"]
        ];
        for (const [bad, reason] of badKeys)
            await assert.rejects(() => consume(door, speech, { url: first, key: bad }), { message: "jarvis: net=" + reason });
        const malformedCredentials = ["fixture-private-key\0suffix", "fixture-private-key\u200bsuffix"];
        for (const value of malformedCredentials) await safeHeaderError(Net, Policy, value);
        await assert.rejects(() => consume(cloud.door, speech, { url: remote, key: { ...key, origin: remote } }),
            { message: "jarvis: net=key-plaintext" });
        await assert.rejects(() => consume(door, speech, { url: first.replace("http:", "ws:") }),
            { message: "jarvis: net=transport" });
        const stopped = owner().door;
        stopped.close();
        await assert.rejects(() => consume(stopped, speech, { url: first }), { message: "jarvis: net=closed" });
        const cancelled = new AbortController();
        cancelled.abort();
        await assert.rejects(() => consume(door, speech, { url: first, signal: cancelled.signal }),
            { message: "jarvis: net=aborted" });
        const streaming = owner().door;
        const stream = await streaming.request(speech, { url: first + "/stream" });
        streaming.close();
        await assert.rejects(() => stream.response.text(), { name: "AbortError" });
        stream.close();

        const channel = door.websocket(speech, { url: first.replace("http:", "ws:") + "/echo", key });
        const opening = once(channel.events, "open");
        const greeting = once(channel.events, "message");
        await opening;
        const [event] = await greeting;
        assert.equal(event.data, "fixture");
        assert.equal(event.target, channel.events, "a raw WebSocket cannot escape in an event");
        assert.equal(event.target.send, undefined);
        assert.equal(records.at(-1).headers.authorization, "Bearer synthetic-key");
        const echo = once(channel.events, "message");
        channel.send(speech);
        assert.equal((await echo)[0].data, "fixture speech");
        assert.equal(frames.at(-1), "fixture speech");
        const binaryEcho = once(channel.events, "message");
        const binaryResult = channel.send(Policy.item(Buffer.from("snapshot"), ["speech"]));
        binaryResult.content.fill(0);
        assert.equal(await (await binaryEcho)[0].data.text(), "snapshot", "returned bytes cannot change a queued frame");
        const closing = once(channel.events, "close");
        channel.close();
        await closing;
        assert.throws(() => channel.send(speech), { message: "jarvis: net=socket-not-open" });
        const closeCases = [
            ["/close-normal", 1000, true],
            ["/close-policy", 1008, true],
            ["/close-abrupt", 1006, false]
        ];
        for (const [route, code, clean] of closeCases) await closeOutcome(Net, Policy, route, code, clean);
        const rejected = door.websocket(speech, { url: first.replace("http:", "ws:") + "/redirect-ws", key });
        const failed = once(rejected.events, "error");
        const count = records.length;
        await failed;
        assert.equal(records.length, count + 1, "WebSocket redirect is not followed");
        assert.throws(() => door.websocket(speech, { url: second.replace("http:", "ws:"), key }), { message: "jarvis: net=key-origin" });

        const cloudSocket = cloud.door.websocket(speech, { url: remote.replace("http:", "ws:") + "/echo" });
        await once(cloudSocket.events, "open");
        assert.equal(cloudSocket.send(fileText).kind, "ask");
        const grantedEcho = once(cloudSocket.events, "message");
        cloudSocket.send(fileText, [{ recipients: cloud.recipients, labels: ["file"] }]);
        // The initial server greeting can arrive before this listener, so
        // wait specifically for the application frame.
        let received = (await grantedEcho)[0].data;
        if (received === "fixture") received = (await once(cloudSocket.events, "message"))[0].data;
        assert.equal(received, "PRIVATE file");
        cloud.door.close();
        assert.throws(() => cloudSocket.send(speech), { message: "jarvis: net=closed" });

        let controls = 0;
        async function control(name, needle, replacement, check) {
            await mutant(file, name, needle, replacement, async (net, folder) =>
                check(net, require(path.join(folder, "Policy.js"))));
            controls++;
        }
        await control("close-outcomes",
            '{ code: event.code, wasClean: event.wasClean }', '{}',
            async (net, policy) => closeOutcome(net, policy, "/close-policy", 1008, true));
        await control("close-clean",
            'wasClean: event.wasClean', 'wasClean: true',
            async (net, policy) => closeOutcome(net, policy, "/close-abrupt", 1006, false));
        await control("header-error",
            'catch { throw new Error("jarvis: net=key-shape"); }', 'catch (error) { throw error; }',
            async (net, policy) => {
                for (const value of malformedCredentials) await safeHeaderError(net, policy, value);
            });
        await mutant(path.join(tree, "shell/plugins/vgs.jarvis/backend/keys.js"), "stored-origin",
            "Net.endpoint(origin).origin", "origin", async (_api, folder) => {
                // The real CLI expects backend/ beside its snapshot's script.
                const target = path.join(folder, "tui-plugin", "backend");
                fs.mkdirSync(target, { recursive: true });
                for (const source of ["Secrets.js", "net.js", "keys.js"])
                    fs.copyFileSync(path.join(folder, source), path.join(target, source));
                storedLocalKey(path.dirname(target));
            }, "Secrets.js");
        controls++;
        await control("key-origin", 'typeof origin !== "string" || origin !== target.origin', "false", refuseKey);
        for (const [name, needle, bad] of [
            ["key-header", '!["authorization", "x-api-key", "xi-api-key"].includes(key.header)', { ...key, header: "host" }],
            ["key-empty", 'key.value === ""', { ...key, value: "" }],
            // Native Headers trims leading line breaks. These cases reach
            // the explicit guard rather than the safe setter-error boundary.
            ["key-newline", '/[\\r\\n]/.test(key.value)', { ...key, prefix: "", value: "\nsecret" }],
            ["key-prefix-type", 'typeof key.prefix !== "string"', { ...key, prefix: undefined }],
            ["key-prefix-newline", '/[\\r\\n]/.test(key.prefix)', { ...key, prefix: "\n" }]
        ]) {
            await control(name, needle, "false",
                async (net, policy) => { const { door } = owner(net, policy);
                    await assert.rejects(() => consume(door, speech, { url: first, key: bad }),
                        { message: "jarvis: net=key-shape" }); });
        }
        for (const [name, needle, value] of [
            ["userinfo", 'url.username !== "" || url.password !== ""', first.replace("http://", "http://user:pass@")],
            ["fragment", 'url.hash !== "" || url.href.endsWith("#")', first + "/#"],
            ["scheme", '!["http:", "https:", "ws:", "wss:"].includes(url.protocol)', "file:///tmp/fixture"]
        ]) {
            await control(name, needle, "false",
                async net => assert.throws(() => net.endpoint(value), { message: "jarvis: net=url" }));
        }
        await control("loopback-domain", "isIP(url.hostname) === 4 &&", "",
            async net => assert.equal(net.endpoint("http://127.0.0.1.evil.test").loopback, false));
        await control("raw-key-header", "if (!METADATA.has(name))", "if (false)",
            async (net, policy) => { const { door } = owner(net, policy);
                await assert.rejects(() => consume(door, speech, { url: first, headers: { Authorization: "unbound" } }),
                    { message: "jarvis: net=header" }); });
        await control("redirect", 'redirect: "manual"', 'redirect: "follow"',
            async (net, policy) => { const { door } = owner(net, policy);
                await assert.rejects(() => consume(door, speech, { url: first + "/redirect/307/other", key }),
                    { message: "jarvis: net=redirect" }); });
        await control("redirect-response", "response.status >= 300 && response.status < 400", "false",
            async (net, policy) => { const { door } = owner(net, policy);
                await assert.rejects(() => consume(door, speech, { url: first + "/redirect/307/other", key }),
                    { message: "jarvis: net=redirect" }); });
        await control("recipient-offline", '!all.some(recipient => recipient.kind === "network" && recipient.origin === target.origin)', "false",
            async (net, policy) => { const { door } = owner(net, policy, first, null);
                const start = connections.length;
                try { await consume(door, speech, { url: offlineTarget + "/echo" }); } catch { /* Verdict is socket creation, not the HTTP reply. */ }
                assert.equal(connections.length, start, "offline must open no non-loopback socket"); });
        await control("release-request", 'if (decision.kind !== "send") return decision;\n        const method',
            'if (false) return decision;\n        const method',
            async (net, policy) => { const { door } = owner(net, policy, remote, null);
                assert.equal((await consume(door, fileText, { url: remote + "/echo" })).kind, "ask"); });
        await control("withheld-request", 'if (decision.kind !== "send") return decision;\n        const method',
            'if (decision.kind === "ask") return decision;\n        const method',
            async (net, policy) => { const { door } = owner(net, policy, remote, null, "trusted", "never");
                assert.equal((await consume(door, screen, { url: remote + "/echo" })).kind, "withhold"); });
        await control("release-handshake", 'if (decision.kind !== "send") return decision;\n        // Node 22',
            'if (false) return decision;\n        // Node 22',
            async (net, policy) => { const { door } = owner(net, policy, remote, null);
                assert.equal(door.websocket(fileText, { url: remote.replace("http:", "ws:") }).kind, "ask"); });
        // The same check appears at connection start. A distinct frame guard
        // must also redden on an already open cloud connection.
        await control("release-frame", 'if (released.kind === "send") socket.send', 'if (true) socket.send',
            async (net, policy) => { const { door } = owner(net, policy, remote, null);
                const socket = door.websocket(speech, { url: remote.replace("http:", "ws:") + "/echo" });
                const greeting = once(socket.events, "message");
                await once(socket.events, "open");
                await greeting;
                const start = frames.length;
                const receipt = once(socket.events, "message");
                socket.send(fileText);
                await receipt;
                assert.equal(frames.length, start, "ungranted frame writes nothing"); });
        await control("event-channel", '{ kind: "channel", events,', '{ kind: "channel", events: socket,',
            async (net, policy) => { const { door } = owner(net, policy);
                const socket = door.websocket(speech, { url: first.replace("http:", "ws:") + "/echo" });
                const greeting = once(socket.events, "message");
                await once(socket.events, "open");
                assert.equal((await greeting)[0].target.send, undefined); });
        await control("localhost-dns", 'if (url.hostname === "localhost") url.hostname = "127.0.0.1";',
            'if (false) url.hostname = "127.0.0.1";',
            async net => assert.equal(net.endpoint(localhost).url, first + "/"));
        await control("plaintext-key", '!target.loopback && !target.origin.startsWith("https:")', "false", refusePlaintext);
        await control("closed-owner", 'if (closed) throw new Error("jarvis: net=closed");\n        const target',
            'if (false) throw new Error("jarvis: net=closed");\n        const target',
            async (net, policy) => { const { door } = owner(net, policy); door.close();
                await assert.rejects(() => consume(door, speech, { url: first }), { message: "jarvis: net=closed" }); });
        await control("closed-frame", 'if (closed) throw new Error("jarvis: net=closed");\n                if (socket',
            'if (false) throw new Error("jarvis: net=closed");\n                if (socket',
            async (net, policy) => { const { door } = owner(net, policy);
                const socket = door.websocket(speech, { url: first.replace("http:", "ws:") + "/echo" });
                await once(socket.events, "open");
                door.close();
                assert.throws(() => socket.send(speech), { message: "jarvis: net=closed" }); });
        await control("transport", "target.websocket !== websocket", "false",
            async (net, policy) => { const { door } = owner(net, policy);
                await assert.rejects(() => consume(door, speech, { url: first.replace("http:", "ws:") }),
                    { message: "jarvis: net=transport" }); });
        await control("stream-cancel", "const abort = () => controller.abort();", "const abort = () => {};",
            async (net, policy) => { const { door } = owner(net, policy);
                const signal = new AbortController(); signal.abort();
                await assert.rejects(() => consume(door, speech, { url: first, signal: signal.signal }),
                    { message: "jarvis: net=aborted" }); });
        console.log("test-jarvis-net: ok controls=" + controls + " requests=" + records.length + " sockets=" + connections.length);
    } finally {
        for (const door of owners) door.close();
        for (const socket of peers) socket.destroy();
        await Promise.all(servers.map(instance => new Promise(resolve => instance.close(resolve))));
        sockets.Socket.prototype.connect = originalConnect;
    }
}, standins)?.catch(error => { console.error(error); process.exitCode = 1; });
