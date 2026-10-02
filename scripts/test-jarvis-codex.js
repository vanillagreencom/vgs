#!/usr/bin/env node
// The Codex harness end to end in J09: the real Session reducer, SessionRunner,
// ToolRouter, Policy, Denied, Audit, ToolBridge with the real mcp-shim,
// HarnessGate and CodexHarness, against fixtures/jarvis-codex/codex-stub.js as
// the vendor program. The stub is built from the codex-cli 0.160.0 schema
// excerpt and replays the sanitized recording beside it; every message the
// harness writes is checked against the excerpt. No vendor program, login,
// account or network is used. Mutants edit disposable plugin copies.
"use strict";
const { assert, fs, path, tree, world, seed } = require("./fixtures/jarvis/policy.js");
const Check = require("./fixtures/schema-check.js");
const excerpt = require("./fixtures/jarvis-codex/app-server.schema.json");
const { load } = require("../bin/lib/qml-library.js");
const Fixture = require("./fixtures/jarvis/engine.js");
const cp = require("node:child_process");
const plugin = path.join(tree, "shell/plugins/vgs.jarvis");
const SCHEMAS = { "initialize": "InitializeParams", "config/read": "ConfigReadParams", "thread/start": "ThreadStartParams",
    "experimentalFeature/list": "ExperimentalFeatureListParams", "turn/start": "TurnStartParams",
    "turn/interrupt": "TurnInterruptParams" };
const ANSWERS = { "item/fileChange/requestApproval": "FileChangeRequestApprovalResponse",
    "item/commandExecution/requestApproval": "CommandExecutionRequestApprovalResponse",
    "item/permissions/requestApproval": "PermissionsRequestApprovalResponse",
    "mcpServer/elicitation/request": "McpServerElicitationRequestResponse" };

world(async () => {
    const Session = load(path.join(plugin, "Session.js"));
    const fixtures = seed();
    const state = process.env.XDG_STATE_HOME;
    fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis-codex/recorded.ndjson"), path.join(state, "codex-recorded.ndjson"));
    const account = path.join(process.env.HOME, ".codex");
    fs.mkdirSync(account);
    const env = { PATH: process.env.PATH, HOME: process.env.HOME, XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME,
        XDG_STATE_HOME: state, XDG_DATA_HOME: process.env.XDG_DATA_HOME, XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR,
        OPENAI_API_KEY: "fixture-secret-private", VGSH_RUNNER_PID: "1" };
    const owners = [];
    let serial = 0, cases = 0;

    async function until(predicate, what, ms = 5000) {
        // Children answer across pipes; poll in real time with a bound.
        for (const end = Date.now() + ms; Date.now() < end;) {
            if (predicate()) return;
            await new Promise(resolve => setTimeout(resolve, 5));
        }
        assert.fail(what + " never held");
    }
    const read = name => fs.existsSync(path.join(state, name))
        ? fs.readFileSync(path.join(state, name), "utf8").trim().split("\n").filter(Boolean).map(line => JSON.parse(line)) : [];
    function scenario(value) {
        for (const name of ["codex-log", "codex-calls"]) fs.rmSync(path.join(state, name), { force: true });
        fs.writeFileSync(path.join(state, "codex-scenario.json"), JSON.stringify(value));
    }
    // The latest program start; a login status check is not one.
    const program = () => read("codex-calls").filter(call => call.args[0] === "app-server").at(-1);
    const received = method => read("codex-log").filter(row => row.direction === "in" && row.message.method === method).map(row => row.message);
    // The answer the harness wrote to the stub's server request of this method.
    function answered(method) {
        const log = read("codex-log");
        const asked = log.filter(row => row.direction === "out" && row.message.method === method).map(row => row.message.id);
        return log.filter(row => row.direction === "in" && row.message.method === undefined && asked.includes(row.message.id))
            .map(row => row.message);
    }
    function validWrites() {
        for (const { direction, message } of read("codex-log")) {
            if (direction !== "in") continue;
            if (message.method !== undefined) {
                assert.deepEqual(Check.errors(excerpt, message.id === undefined ? "JSONRPCNotification" : "JSONRPCRequest", message), [], message.method);
                if (SCHEMAS[message.method]) assert.deepEqual(Check.errors(excerpt, SCHEMAS[message.method], message.params), [], message.method);
            } else assert.deepEqual(Check.errors(excerpt, message.error ? "JSONRPCError" : "JSONRPCResponse", message), [], "answer");
        }
        const log = read("codex-log");
        for (const row of log.filter(row => row.direction === "out" && ANSWERS[row.message.method])) {
            const answer = log.find(entry => entry.direction === "in" && entry.message.method === undefined && entry.message.id === row.message.id);
            if (answer?.message.result) assert.deepEqual(Check.errors(excerpt, ANSWERS[row.message.method], answer.message.result), [], row.message.method);
        }
    }

    /** One daemon-side world loaded from a plugin folder. */
    function make(folder = plugin, options = {}) {
        const need = name => require(path.join(folder, "backend", name));
        const Router = need("ToolRouter.js"), Bridge = need("ToolBridge.js"), Audit = need("Audit.js"), Gate = need("HarnessGate.js");
        const Policy = need("Policy.js"), Denied = need("Denied.js"), Harness = need("CodexHarness.js");
        const { SessionRunner, unavailable } = need("session-runner.js");
        const root = path.join(process.env.JARVIS_TEST_ROOT, "c" + ++serial);
        fs.mkdirSync(root);
        let at = 0, transcript;
        const starts = [], brainResults = [];
        const audit = Audit.create({ state: path.join(root, "state"), now: () => Date.UTC(2026, 9, 2) });
        const rows = () => { const file = path.join(root, "state/audit/2026-10-02.jsonl");
            return fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim().split("\n").map(line => JSON.parse(line)) : []; };
        const ports = { ...unavailable(), mute: { store() {} },
            capture: { open: (e, done) => done(), close: (e, done) => done(), collect: (e, done) => { transcript = done; } },
            brain: { send() {}, cancel: (e, done) => done(), close() {} } };
        const runner = new SessionRunner(Session, ports, { now: () => at, set: () => ({}), clear() {} }, () => {});
        let bridge = null, gate = null;
        const router = Router.create({ session: Session, state: () => runner.state, dispatch: e => runner.dispatch(e),
            context: () => ({ profile: options.profile ?? "standard", locked: false, denied: Denied.create(fixtures.roots) }),
            audit, result: value => gate.deliver(value) || bridge.deliver(value) || brainResults.push(value) });
        Object.assign(ports, router.ports);
        router.register("windows", { commands: ["hyprctl"], timeoutMs: 1000, cancellable: false,
            start: (call, done) => starts.push({ call, done }) });
        gate = Gate.create({ router, state: () => runner.state });
        router.register("harness", gate.executor);
        const runtime = path.join(process.env.JARVIS_TEST_ROOT, "r" + serial.toString(36));
        bridge = Bridge.create({ router, state: () => runner.state, audit, directory: runtime });
        runner.dispatch({ type: "snapshot", locked: false, engine: "chained", configured: true, settings: {} });
        runner.dispatch({ type: "indicator", shown: true });
        runner.dispatch({ type: "talk-down" });
        transcript("final", "fixture user");
        const recipients = Policy.recipients({ conversation: "codex-" + serial, profile: "standard", cloudVision: "ask",
            brain: { kind: "network", provider: "codex", account: "fixture", origin: "https://chatgpt.com" },
            speech: [{ kind: "local", provider: "fixture-speech", account: "" }] });
        const brain = Harness.create({ model: options.model ?? "", recipients, account: { kind: "cli", directory: account },
            gen: runner.state.gen, harness: { bridge, gate, env, runtime: () => runtime } });
        brain.start({ instructions: "Be brief.", tools: [] });
        owners.push(() => { brain.close(); bridge.close(); gate.close(); audit.close(); });
        return { Policy, Harness, Gate, runner, router, gate, bridge, brain, rows, starts, runtime, recipients, root, audit,
            time: value => { at = value; },
            show: () => runner.dispatch({ type: "shown", gen: runner.state.gen, op: runner.state.approval.op, id: runner.state.approval.id }),
            confirm: () => runner.dispatch({ type: "confirm", gen: runner.state.gen, id: runner.state.approval.id,
                digest: runner.state.approval.digest, source: "key" }),
            say: (text, labels = ["speech"]) => brain.send({ kind: "user", items: [Policy.item(text, labels)] }) };
    }
    // A turn crosses the stub's pipes; a lost answer fails its case.
    async function drain(reply) {
        const events = [];
        let timer;
        const limit = new Promise((resolve, reject) => {
            timer = setTimeout(() => reject(new assert.AssertionError({ message: "turn timeout" })), 8000);
        });
        const read = (async () => { for await (const event of reply.events) events.push(event); })();
        try { await Promise.race([read, limit]); } finally { clearTimeout(timer); }
        return events;
    }
    const delta = text => ({ notify: "item/agentMessage/delta", params: { threadId: "$THREAD", turnId: "$TURN", itemId: "m1", delta: text } });
    const fileItem = (method, changes, status) => ({ notify: method, params: { threadId: "$THREAD", turnId: "$TURN",
        [method === "item/started" ? "startedAtMs" : "completedAtMs"]: 1, item: { type: "fileChange", id: "call_patch", changes, status } } });
    const approval = (method, extra = {}) => ({ request: method, params: { threadId: "$THREAD", turnId: "$TURN",
        itemId: "call_patch", startedAtMs: 1, ...extra } });
    const added = file => [{ path: file, kind: { type: "add" }, diff: "+fixture\n" }];
    const newFile = path.join(fixtures.project, "new");
    const existing = path.join(fixtures.project, "existing");

    const CASES = {
        // The handshake's lockdown, the scrubbed program environment and a streamed turn.
        async turn(folder) {
            scenario({ servers: { userfs: { command: "fixture-server", env: { TOKEN: "fixture-secret-private" } } },
                turns: [[delta("Hel"), delta("lo."), { complete: "completed" }]] });
            const w = make(folder);
            const events = await drain(w.say("hi"));
            assert.deepEqual(events, [{ kind: "text", text: "Hel" }, { kind: "text", text: "lo." }, { kind: "done", reason: "stop" }]);
            const [call] = read("codex-calls");
            assert.deepEqual(call.args, ["app-server", "--listen", "stdio://"]);
            assert.equal(call.env.CODEX_HOME, account, "the account's own directory");
            for (const name of ["OPENAI_API_KEY", "VGSH_RUNNER_PID", "VGS_JARVIS_TOOLS_TOKEN"])
                assert.equal(Object.hasOwn(call.env, name), false, name + " stays out of the program's environment");
            assert.equal(path.dirname(call.cwd), w.runtime, "a private working directory");
            const [start] = received("thread/start");
            const servers = start.params.config.mcp_servers;
            assert.deepEqual(Object.keys(servers).sort(), ["userfs", "vgs_jarvis"]);
            assert.deepEqual(servers.userfs, { enabled: false }, "the user's own server is switched off");
            assert.equal(servers.vgs_jarvis.env.VGS_JARVIS_TOOLS_SOCKET, path.join(w.runtime, "tools.sock"));
            assert.match(servers.vgs_jarvis.env.VGS_JARVIS_TOOLS_TOKEN, /^[0-9a-f]{64}$/);
            assert.equal(JSON.stringify(call.args).includes(servers.vgs_jarvis.env.VGS_JARVIS_TOOLS_TOKEN), false);
            assert.equal(start.params.config.features.shell_tool, false);
            assert.deepEqual([start.params.approvalPolicy, start.params.approvalsReviewer, start.params.sandbox, start.params.ephemeral],
                ["untrusted", "user", "read-only", true]);
            assert.equal(received("experimentalFeature/list").length, 1, "the features are judged before a turn");
            assert.deepEqual(received("turn/start").map(m => m.params.input[0].text), ["hi"]);
            validWrites();
        },
        // Only released content reaches the program; a file needs a grant.
        async release(folder) {
            scenario({ turns: [[{ complete: "completed" }]] });
            const w = make(folder);
            const reply = w.brain.send({ kind: "user", items: [w.Policy.item("spoken", ["speech"]), w.Policy.item("secret notes", ["file"])] });
            assert.deepEqual([...reply.release.labels], ["speech"]);
            assert.deepEqual([...reply.release.needed], ["file"]);
            await drain(reply);
            const [turn] = received("turn/start");
            assert.equal(turn.params.input[0].text, "spoken\n\n[withheld: file text]");
            const empty = make(folder);
            await assert.rejects(drain(empty.say("only a file", ["file"])), { message: "jarvis: brain=codex-release-empty" });
        },
        // An allowed file change: the gate audits it before the program is told to proceed.
        async allowed(folder) {
            scenario({ turns: [[fileItem("item/started", added(newFile), "inProgress"), approval("item/fileChange/requestApproval"),
                fileItem("item/completed", added(newFile), "completed"), delta("Done."), { complete: "completed" }]] });
            const w = make(folder);
            await drain(w.say("make a file"));
            assert.deepEqual(answered("item/fileChange/requestApproval").map(m => m.result), [{ decision: "accept" }]);
            const actions = w.rows().filter(row => row.kind === "action");
            assert.deepEqual(actions.map(row => [row.tool, row.decision, row.outcome]),
                [["harness.files", "allow", "pending"], ["harness.files", "allow", "completed"]]);
            validWrites();
        },
        // An overwrite is held for physical confirmation; the program waits.
        async held(folder) {
            const changes = [{ path: existing, kind: { type: "update", move_path: null }, diff: "-a\n+b\n" }];
            scenario({ turns: [[fileItem("item/started", changes, "inProgress"), approval("item/fileChange/requestApproval"),
                fileItem("item/completed", changes, "completed"), { complete: "completed" }]] });
            const w = make(folder);
            const done = drain(w.say("edit it"));
            // An assertion below may leave this turn unread; its own failure is not the finding.
            done.catch(() => {});
            await until(() => w.runner.state.approval.kind === "held", "the approval is held");
            assert.equal(w.runner.state.approval.physical, true);
            assert.match(w.runner.state.approval.text, new RegExp("Write \\[\"" + existing + "\"\\]"));
            assert.deepEqual(answered("item/fileChange/requestApproval"), [], "no answer before the user confirms");
            // A second request while one is held is refused and leaves the held one startable.
            let declined = 0;
            const second = w.gate.ask(w.runner.state.gen, { tool: "harness.files", arguments: {} },
                { decline: () => declined++, accept: () => assert.fail("accepted") });
            assert.deepEqual([second, declined], [{ kind: "refuse", reason: "busy" }, 1]);
            w.show(); w.time(700); w.confirm();
            await done;
            assert.deepEqual(answered("item/fileChange/requestApproval").map(m => m.result), [{ decision: "accept" }]);
            assert.deepEqual(w.rows().filter(row => row.kind === "action").map(row => [row.decision, row.confirmed, row.outcome]),
                [["confirm", "none", "pending"], ["refuse", "none", "cancelled"], ["confirm", "physical", "pending"],
                    ["confirm", "physical", "completed"]]);
        },
        // Refusals: a protected path, the program's own command, a permission request.
        async refused(folder) {
            const blocked = path.join(fixtures.home, ".ssh", "id_fixture");
            scenario({ turns: [[fileItem("item/started", added(blocked), "inProgress"), approval("item/fileChange/requestApproval"),
                approval("item/commandExecution/requestApproval", { command: "cat ~/.ssh/id_fixture", cwd: fixtures.project }),
                approval("item/permissions/requestApproval", { cwd: fixtures.project, permissions: {} }),
                { complete: "completed" }]] });
            const w = make(folder);
            await drain(w.say("try"));
            assert.deepEqual(answered("item/fileChange/requestApproval").map(m => m.result), [{ decision: "decline" }]);
            assert.deepEqual(answered("item/commandExecution/requestApproval").map(m => m.result), [{ decision: "decline" }]);
            assert.deepEqual(answered("item/permissions/requestApproval").map(m => m.result), [{ permissions: {}, scope: "turn" }]);
            assert.deepEqual(w.rows().filter(row => row.kind === "action").map(row => [row.tool, row.decision, row.outcome]),
                [["harness.files", "refuse", "cancelled"], ["harness.command", "refuse", "cancelled"], ["unknown", "refuse", "cancelled"]]);
            validWrites();
        },
        // A request outside the live turn never reaches the router.
        async stale(folder) {
            scenario({ turns: [[approval("item/fileChange/requestApproval", { turnId: "another-turn" }), { complete: "completed" }]] });
            const w = make(folder);
            await drain(w.say("x"));
            assert.deepEqual(answered("item/fileChange/requestApproval").map(m => m.result), [{ decision: "decline" }]);
            assert.deepEqual(w.rows().filter(row => row.kind === "action"), []);
            // The gate itself declines a request from a generation that is not live.
            let declined = 0;
            const answer = w.gate.ask(w.runner.state.gen + 1, { tool: "harness.files", arguments: {} },
                { decline: () => declined++, accept: () => assert.fail("accepted") });
            assert.deepEqual([answer, declined], [{ kind: "refuse", reason: "stale-turn" }, 1]);
            assert.deepEqual(w.rows().filter(row => row.kind === "action"), []);
        },
        // The bridge's own tool calls: Codex asks first, then calls through the real shim.
        async bridge(folder) {
            const elicit = (server, kind, mode = "form") => ({ request: "mcpServer/elicitation/request", params: { threadId: "$THREAD", turnId: "$TURN",
                serverName: server, mode, message: "Allow?", requestedSchema: { type: "object", properties: {} },
                _meta: { codex_approval_kind: kind } } });
            scenario({ turns: [[elicit("vgs_jarvis", "mcp_tool_call"), elicit("userfs", "mcp_tool_call"), elicit("vgs_jarvis", "other"),
                { mcp: { tool: "windows_list", arguments: {} } },
                { request: "item/tool/requestUserInput", params: { threadId: "$THREAD", turnId: "$TURN", itemId: "q", questions: [] } },
                { complete: "completed" }]] });
            const w = make(folder);
            const done = drain(w.say("list windows"));
            // An assertion below may leave this turn unread; its own failure is not the finding.
            done.catch(() => {});
            await until(() => w.starts.length === 1, "the bridge call reaches the windows executor");
            assert.equal(w.starts[0].call.id, "windows.list");
            w.starts[0].done({ outcome: "completed", content: "[]" });
            await done;
            assert.deepEqual(answered("mcpServer/elicitation/request").map(m => m.result.action), ["accept", "decline", "decline"]);
            const [mcp] = read("codex-log").filter(row => row.direction === "mcp").map(row => row.message);
            assert.ok(mcp.tools.includes("windows_list"));
            assert.equal(mcp.tools.some(name => name.startsWith("harness_")), false, "no harness row is offered");
            assert.deepEqual(mcp.result.result, { content: [{ type: "text", text: "[]" }], isError: false });
            assert.deepEqual(answered("item/tool/requestUserInput").map(m => m.error.code), [-32601]);
            validWrites();
        },
        // The program's own reply proves the lockdown; anything else refuses the brain.
        async lockdown(folder) {
            for (const [label, value, message] of [
                ["policy", { thread: { approvalPolicy: "never" } }, "jarvis: brain=codex-lockdown"],
                ["reviewer", { thread: { approvalsReviewer: "auto_review" } }, "jarvis: brain=codex-lockdown"],
                ["feature", { features: [{ name: "fixture_tool", stage: "stable", enabled: true, defaultEnabled: true }] },
                    "jarvis: brain=codex-feature name=fixture_tool"],
                ["server-name", { servers: { vgs_jarvis: { command: "x" } } }, "jarvis: brain=codex-mcp-name"],
                ["crash", { crash: "handshake" }, "jarvis: brain=codex-exited code=3 signal=null"]
            ]) {
                scenario({ ...value, turns: [[{ complete: "completed" }]] });
                const w = make(folder);
                await assert.rejects(drain(w.say("x")), { message }, label);
                assert.deepEqual(received("turn/start"), [], label + " starts no turn");
                await until(() => fs.readdirSync(w.runtime).every(name => !name.startsWith("codex-")), label + " removes its directory");
            }
        },
        // cancel interrupts the program's turn and resolves on its acknowledgement.
        async cancel(folder) {
            scenario({ turns: [[delta("a"), { interrupt: true }]] });
            const w = make(folder);
            const reply = w.say("long");
            const iterator = reply.events[Symbol.asyncIterator]();
            assert.deepEqual((await iterator.next()).value, { kind: "text", text: "a" });
            await w.brain.cancel();
            assert.equal(received("turn/interrupt").length, 1);
            await assert.rejects(iterator.next(), { message: "jarvis: brain=cancelled" });
            validWrites();
        },
        // close ends the program, the bridge session and the private directory.
        async close(folder) {
            scenario({ turns: [[{ complete: "completed" }]] });
            const w = make(folder);
            await drain(w.say("x"));
            const socket = path.join(w.runtime, "tools.sock");
            assert.ok(fs.existsSync(socket));
            w.brain.close();
            await until(() => !fs.existsSync(socket), "the bridge session closes");
            await until(() => fs.readdirSync(w.runtime).every(name => !name.startsWith("codex-")), "the directory is removed");
            await until(() => !process.getActiveResourcesInfo().includes("ProcessWrap"), "the program exits");
            assert.throws(() => w.say("again"), { message: "jarvis: brain=codex-closed" });
        },
        // A close while the bridge session is still opening ends that session
        // too, so the next conversation opens its own.
        async opening(folder) {
            scenario({ turns: [[{ complete: "completed" }]] });
            const w = make(folder);
            let opened = null;
            const brain = bridge => w.Harness.create({ model: "", recipients: w.recipients, account: { kind: "cli", directory: account },
                gen: w.runner.state.gen, harness: { bridge, gate: w.gate, env, runtime: () => w.runtime } });
            const send = value => value.send({ kind: "user", items: [w.Policy.item("x", ["speech"])] });
            const first = brain({ open: value => (opened = w.bridge.open(value)) });
            first.start({ instructions: "Be brief.", tools: [] });
            const read = drain(send(first));
            assert.notEqual(opened, null, "the bridge session is opening");
            first.close();
            await assert.rejects(read, { message: "jarvis: brain=cancelled" });
            // The harness's own continuation of this open runs first.
            await opened;
            const next = brain(w.bridge);
            owners.unshift(() => next.close());
            next.start({ instructions: "Be brief.", tools: [] });
            await assert.doesNotReject(drain(send(next)), "a later conversation opens its bridge session");
        },
        // The plan's context bound in user turns: past it the chained engine
        // ends the conversation cleanly, as it does a wire brain's.
        async limit(folder) {
            scenario({ turns: Array.from({ length: 41 }, () => [{ complete: "completed" }]) });
            // The world loads the engine's own module copies: a recipient set is
            // judged by the Policy module that made it.
            const { folder: copied, Engine } = Fixture.copy(process.env.JARVIS_TEST_ROOT, [], folder);
            const w = make(copied);
            const engine = Engine.create({ session: Session, state: () => w.runner.state, audit: w.audit, router: w.router,
                accounts: () => ({ secrets: null, resolve: id => ({ id, provider: "codex", label: "default",
                    source: { kind: "cli", directory: account }, model: "" }) }),
                policy: () => ({ profile: "standard", cloudVision: "ask" }), fault: reason => assert.fail("fault " + reason),
                harness: { bridge: w.bridge, gate: w.gate, env, runtime: () => w.runtime } });
            owners.unshift(() => engine.close());
            assert.deepEqual(engine.configure({ brain: "codex-fixture" }), { kind: "ready" });
            const { gen, turn: { op } } = w.runner.state;
            const send = text => new Promise(resolve => engine.brain.send({ gen, op, owner: 1, text },
                (verdict, detail) => resolve([verdict, detail])));
            for (let turn = 0; turn < 40; turn++) assert.deepEqual(await send("turn " + turn), ["brain-done", undefined]);
            assert.deepEqual(await send("one more"), ["brain-ended", { reason: "brain=context-limit" }]);
        },
        // Account Verify on a Codex directory: the release record, then one probe turn.
        async verify(folder) {
            const { Accounts } = require(path.join(folder, "backend/Accounts.js"));
            const directory = path.join(state, "vgs/jarvis");
            fs.rmSync(path.join(directory, "audit"), { recursive: true, force: true });
            fs.mkdirSync(path.join(process.env.HOME, ".claude"), { recursive: true });
            // Verify's program runs in the runtime directory its owner hands over.
            const runtime = path.join(process.env.JARVIS_TEST_ROOT, "verify-runtime");
            const judge = new Accounts(directory, env, undefined, runtime);
            const found = judge.discover();
            const codex = found.find(item => item.provider === "codex" && item.source.directory === account);
            const claude = found.find(item => item.provider === "claude");
            assert.equal(codex.state.kind, "signed-in");
            assert.deepEqual(judge.resolve(codex.id), { id: codex.id, provider: "codex", label: "default",
                source: { kind: "cli", directory: account }, model: "" });
            assert.equal(judge.resolve(claude.id), null, "a subscription the engine cannot run is no brain");
            scenario({ reply: "OK" });
            assert.deepEqual(await judge.verify(codex.id, "user"), { kind: "verified" });
            assert.deepEqual(read("codex-log").filter(row => row.direction === "audit").map(row => row.message.lines), [1],
                "the release record precedes the program's turn");
            assert.deepEqual(received("turn/start").map(m => m.params.input[0].text), ["Reply OK."]);
            assert.equal(path.dirname(program().cwd), runtime, "the owner's runtime directory");
            const audit = fs.readdirSync(path.join(directory, "audit")).flatMap(name =>
                fs.readFileSync(path.join(directory, "audit", name), "utf8").trim().split("\n").map(line => JSON.parse(line)));
            assert.deepEqual(audit.map(row => [row.kind, row.decision, row.outcome]),
                [["release", "send", "pending"], ["release", "send", "completed"]]);
            assert.equal(JSON.stringify(judge.status()).includes("OK"), false, "no reply text reaches status");
            scenario({ turns: [[{ complete: "failed" }]] });
            assert.deepEqual(await judge.verify(codex.id, "user"), { kind: "unavailable", reason: "codex-turn-failed" });
            // The helper the accounts terminal runs: a refused turn is its keyed
            // refusal, with nothing after it on stderr.
            scenario({ refuse: "turn/start" });
            const helper = cp.spawnSync("node", [path.join(folder, "backend/accounts.js"), "verify", codex.id, "user"],
                { env, encoding: "utf8", timeout: 30000 });
            assert.deepEqual([helper.status, helper.stdout, helper.stderr],
                [69, JSON.stringify({ kind: "unavailable", reason: "codex-refused" }) + "\n", ""]);
            assert.equal(path.dirname(program().cwd), path.join(env.XDG_RUNTIME_DIR, "vgs/jarvis"),
                "the helper hands over the daemon's runtime directory");
        },
        // Account Verify's handoff: one turn on a thread with no tools.
        async probe(folder) {
            const Harness = require(path.join(folder, "backend/CodexHarness.js"));
            const runtime = path.join(process.env.JARVIS_TEST_ROOT, "probe");
            scenario({ reply: "OK", servers: { userfs: {} } });
            assert.equal(await Harness.probe({ directory: account, env, runtime, model: "", text: "Reply OK." }), "OK");
            const [start] = received("thread/start");
            assert.deepEqual(start.params.config.mcp_servers, { userfs: { enabled: false } }, "a probe thread has no tools");
            assert.equal(start.params.baseInstructions, "Answer in one word.");
            assert.deepEqual(received("turn/start").map(m => m.params.input[0].text), ["Reply OK."]);
            assert.deepEqual(fs.readdirSync(runtime), []);
            scenario({ reply: " " });
            await assert.rejects(Harness.probe({ directory: account, env, runtime, model: "", text: "Reply OK." }),
                { message: "jarvis: brain=codex-no-reply" });
            scenario({ turns: [[{ complete: "failed" }]] });
            await assert.rejects(Harness.probe({ directory: account, env, runtime, model: "", text: "Reply OK." }),
                { message: "jarvis: brain=codex-turn-failed" });
            validWrites();
        }
    };

    async function variant(relative, edits, check) {
        const folder = fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "variant-"));
        fs.mkdirSync(path.join(folder, "backend"));
        for (const name of fs.readdirSync(plugin).filter(name => name.endsWith(".js")))
            fs.copyFileSync(path.join(plugin, name), path.join(folder, name));
        for (const name of fs.readdirSync(path.join(plugin, "backend")).filter(name => name.endsWith(".js") || name === "mcp-shim"))
            fs.copyFileSync(path.join(plugin, "backend", name), path.join(folder, "backend", name));
        fs.cpSync(path.join(plugin, "backend/skills"), path.join(folder, "backend/skills"), { recursive: true });
        const target = path.join(folder, relative);
        let source = fs.readFileSync(target, "utf8");
        for (const [needle, replacement] of edits) {
            assert.equal(source.split(needle).length - 1, 1, relative + " match: " + needle);
            source = source.replace(needle, replacement);
        }
        fs.writeFileSync(target, source);
        await assert.rejects(check(folder), assert.AssertionError, relative + " variant must turn red: " + edits[0][0]);
        for (const owner of owners.splice(0)) owner();
    }

    try {
        for (const [name, check] of Object.entries(CASES)) {
            await check(plugin);
            for (const owner of owners.splice(0)) owner();
            cases++;
            console.log("case=" + name + " passed");
        }
        let controls = 0;
        for (const [name, relative, edits, row] of [
            ["environment-scrub", "backend/CodexHarness.js", [["env: { ...childEnvironment(env), CODEX_HOME", "env: { ...env, CODEX_HOME"]], "turn"],
            ["account-home", "backend/CodexHarness.js", [["CODEX_HOME: directory }", "CODEX_HOME: env.HOME }"]], "turn"],
            ["feature-check", "backend/CodexHarness.js", [["Codex.features(await p.call(id => Codex.featureList(id, thread)));", ""]], "turn"],
            ["feature-judged", "backend/CodexHarness.js", [["Codex.features(await p.call(id => Codex.featureList(id, thread)));",
                "await p.call(id => Codex.featureList(id, thread));"]], "lockdown"],
            ["foreign-servers", "backend/CodexHarness.js", [["const foreign = Codex.servers(", "const foreign = [] || Codex.servers("]], "turn"],
            ["bridge-launch", "backend/CodexHarness.js", [["instructions, bridge: launch }", "instructions, bridge: null }"]], "bridge"],
            ["release", "backend/CodexHarness.js", [["const decision = Policy.release(item, recipients, grants);",
                "const decision = { kind: \"send\", content: item.content };"]], "release"],
            ["release-empty", "backend/CodexHarness.js", [['if (labels.length === 0) fail("release-empty");', ""]], "release"],
            ["gate-routing", "backend/CodexHarness.js", [["gate.ask(gen, Codex.proposal(value, turn.items.get(value.itemId) ?? null), {",
                "({ ask: (gen, proposal, port) => port.accept() }).ask(gen, Codex.proposal(value, turn.items.get(value.itemId) ?? null), {"]], "allowed"],
            ["turn-binding", "backend/CodexHarness.js", [[" || value.turnId !== turn.id) { respond(false); return; }", ") { respond(false); return; }"]], "stale"],
            ["elicitation-server", "backend/CodexHarness.js", [[" && value.server === Codex.SERVER", ""]], "bridge"],
            ["elicitation-kind", "backend/CodexHarness.js", [["respond(value.toolCall && ", "respond(true || "]], "bridge"],
            ["interrupt", "backend/CodexHarness.js", [["session.program.call(id => Codex.turnInterrupt(id, session.thread, current.id)).catch(() => {});",
                "acknowledged();"]], "cancel"],
            ["bridge-close", "backend/CodexHarness.js", [["launch?.close();", ""]], "close"],
            ["directory-removal", "backend/CodexHarness.js", [["    await session.program.close();\n    fs.rmSync(session.cwd, { recursive: true, force: true });",
                "    await session.program.close();"]], "close"],
            ["context-limit", "backend/CodexHarness.js", [['if (turns >= TURNS) throw new Error("jarvis: brain=context-limit");', ""]], "limit"],
            ["context-key", "backend/CodexHarness.js", [['throw new Error("jarvis: brain=context-limit");', 'fail("context-limit");']], "limit"],
            ["opening-close", "backend/CodexHarness.js", [['if (closed) { launch.close(); fail("closed"); }', 'if (closed) fail("closed");']], "opening"],
            ["probe-observed", "backend/CodexHarness.js", [["done.catch(() => {});", "void done;"]], "verify"],
            ["probe-reply", "backend/CodexHarness.js", [['if (reply.trim() === "") fail("no-reply");', ""]], "probe"],
            ["probe-tools", "backend/CodexHarness.js", [["instructions: PROBE_INSTRUCTIONS, bridge: null }", "instructions: PROBE_INSTRUCTIONS, bridge: { command: \"x\", args: [], env: {} } }"]], "probe"],
            ["probe-status", "backend/CodexHarness.js", [['if (e.status === "completed") settle.resolve();', "if (true) settle.resolve();"]], "probe"],
            ["gate-decline", "backend/HarnessGate.js", [["            entry.port.decline();\n", "\n"]], "refused"],
            ["gate-stale", "backend/HarnessGate.js", [['if (closed || s.gen !== gen || s.turn.kind !== "thinking")', "if (closed)"]], "stale"],
            ["gate-requests", "backend/HarnessGate.js", [["pending.set(id, entry);", "pending.clear();\n        pending.set(id, entry);"]], "held"],
            ["gate-held", "backend/HarnessGate.js", [["return router.route(", "entry.port.accept();\n        return router.route("]], "held"],
            ["handoff-route", "backend/Accounts.js", [['case "codex":', 'case "codex-removed":']], "verify"],
            ["handoff-audit", "backend/Accounts.js", [["release.start(() => CodexHarness.probe(",
                "(send => send())(() => CodexHarness.probe("]], "verify"],
            ["handoff-release", "backend/Accounts.js", [['const grants = [{ recipients: selected, labels: ["command"] }];', "const grants = [];"]], "verify"],
            ["resolve-handoff", "backend/Accounts.js", [["if (!HARNESS_BRAINS.includes(candidate.provider)) return null;", ""]], "verify"],
            ["handoff-runtime", "backend/Accounts.js", [["runtime: this.runtime,", 'runtime: path.join(this.env.XDG_RUNTIME_DIR, "vgs/jarvis"),']], "verify"],
            ["default-runtime", "backend/Accounts.js", [["runtime = runtimeDirectory(env.XDG_RUNTIME_DIR)) {", 'runtime = "") {']], "verify"],
            ["harness-reason", "backend/Accounts.js", [[": harness ? harness[1]", ": false ? harness[1]"]], "verify"],
            ["gate-outcome", "backend/CodexHarness.js", [['outcome: item.status === "completed" ? "completed"', 'outcome: item.status === "unreachable" ? "completed"']], "allowed"]
        ]) {
            await variant(relative, edits, folder => CASES[row](folder));
            controls++;
            console.log("control=" + name + " detected");
        }
        console.log("test-jarvis-codex: ok cases=" + cases + " controls=" + controls);
    } finally { for (const owner of owners.splice(0)) owner(); }
}, standins => {
    fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis-codex/codex-stub.js"), path.join(standins, "codex"));
    fs.chmodSync(path.join(standins, "codex"), 0o700);
}, 300000);
