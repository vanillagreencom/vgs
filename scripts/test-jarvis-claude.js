#!/usr/bin/env node
// The Claude Code harness end to end: the real ClaudeCode adapter starts the
// stand-in `claude` (fixtures/jarvis-claude/claude), which speaks the pinned
// stream-json excerpt and starts the real mcp-shim from the adapter's MCP
// configuration. Its tool calls reach the real ToolBridge, ToolRouter, Policy,
// Session approval and Audit on scratch state, with stand-in executors. The
// account Verify rows run the real Accounts judge through the same adapter.
// Everything runs in J09: no login, model, network or host program.
"use strict";
const { assert, fs, path, tree, world, seed, mutant } = require("./fixtures/jarvis/policy.js");
const { load } = require("../bin/lib/qml-library.js");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const harnessFile = path.join(backend, "ClaudeCode.js");
const accountsFile = path.join(backend, "Accounts.js");
const stub = path.join(tree, "scripts/fixtures/jarvis-claude/claude");

// The argv contract, pinned here and not derived from the adapter: built-in
// tools off, only the bridge, its tools unprompted, no hooks, slash commands
// or session files. CONFIG and the trailing prompt flags vary per case.
const ARGV = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
    "--tools", "", "--strict-mcp-config", "--mcp-config", "CONFIG",
    "--allowedTools", "mcp__vgs-jarvis", "--permission-mode", "dontAsk",
    "--settings", "{\"disableAllHooks\":true}", "--disable-slash-commands", "--no-session-persistence"];
const ENVIRONMENT = ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "CLAUDE_CONFIG_DIR", "HOME", "LANG", "PATH",
    "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR", "XDG_STATE_HOME"];
// Keys, tokens and a runner pid planted in the environment handed to the
// adapter and to Verify; none may reach the vendor program.
const PLANTED = { ANTHROPIC_API_KEY: "planted-anthropic-key", CLAUDE_CODE_OAUTH_TOKEN: "planted-oauth-token",
    VGS_JARVIS_TOOLS_TOKEN: "planted-tools-token", VGSH_RUNNER_PID: "424242" };
const leaked = call => Object.values(call.env).filter(value => Object.values(PLANTED).includes(value));

world(async () => {
    const Session = load(path.join(tree, "shell/plugins/vgs.jarvis/Session.js"));
    const fixtures = seed();
    const owners = [];
    const held = () => process.getActiveResourcesInfo().filter(name => /Pipe|Process|TCP/.test(name)).sort();
    void process.stdout; void process.stderr;
    const baseline = held();
    let serial = 0;

    // A child crosses pipes and a socket; a lost line fails, never hangs.
    function bounded(promise, what, ms = 5000) {
        let timer;
        const limit = new Promise((resolve, reject) => {
            timer = setTimeout(() => reject(new assert.AssertionError({ message: what + " timeout" })), ms);
        });
        return Promise.race([promise, limit]).finally(() => clearTimeout(timer));
    }
    const lines = file => fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : [];

    /** One account directory holding the stand-in's script. */
    function account(script, folder = path.join(process.env.JARVIS_TEST_ROOT, "accounts", "a" + ++serial)) {
        fs.mkdirSync(folder, { recursive: true, mode: 0o700 });
        fs.writeFileSync(path.join(folder, "script.json"), JSON.stringify({ tree, ...script }));
        return { directory: folder, calls: () => lines(path.join(folder, "calls.jsonl")),
            events: () => lines(path.join(folder, "events.jsonl")) };
    }

    /** One daemon-side world and one harness conversation from a backend folder. */
    async function make(folder, script, options = {}) {
        const need = name => require(path.join(folder, name));
        const Router = need("ToolRouter.js"), Bridge = need("ToolBridge.js"), Audit = need("Audit.js");
        const Policy = need("Policy.js"), Denied = need("Denied.js"), ClaudeCode = need("ClaudeCode.js");
        const { SessionRunner, unavailable } = need("session-runner.js");
        if (!fs.existsSync(path.join(folder, "mcp-shim"))) fs.copyFileSync(path.join(backend, "mcp-shim"), path.join(folder, "mcp-shim"));
        const root = path.join(process.env.JARVIS_TEST_ROOT, "w" + ++serial);
        fs.mkdirSync(root);
        let at = 0, locked = false, transcript;
        const starts = [], answers = [], brain = [], timers = [];
        const audit = Audit.create({ state: path.join(root, "state"), now: () => Date.UTC(2026, 9, 2) });
        const rows = () => lines(path.join(root, "state/audit/2026-10-02.jsonl"));
        const ports = { ...unavailable(), mute: { store() {} },
            capture: { open: (e, done) => done(), close: (e, done) => done(), collect: (e, done) => { transcript = done; } },
            brain: { send() {}, cancel: (e, done) => done(), close() {} } };
        const runner = new SessionRunner(Session, ports, { now: () => at, set: () => ({}), clear() {} }, () => {});
        let bridge = null;
        const router = Router.create({ session: Session, state: () => runner.state, dispatch: e => runner.dispatch(e),
            context: () => ({ profile: "standard", locked, denied: Denied.create(fixtures.roots) }),
            audit, result: value => bridge.deliver(value) || brain.push(value) });
        Object.assign(ports, router.ports);
        for (const executor of ["windows", "sandbox"])
            router.register(executor, { commands: ["hyprctl", "bwrap"], timeoutMs: 1000, cancellable: true,
                start: (call, done) => { starts.push({ call, audit: rows().at(-1) }); answers.push(done); },
                cancel: () => {} });
        runner.dispatch({ type: "snapshot", locked: false, engine: "chained", configured: true, settings: {} });
        runner.dispatch({ type: "indicator", shown: true });
        runner.dispatch({ type: "talk-down" });
        transcript("final", "fixture user");
        const recipients = Policy.recipients({ conversation: "claude-" + serial, profile: "standard", cloudVision: "ask",
            brain: { kind: "network", provider: "claude", account: "fixture", origin: "https://api.anthropic.com" },
            speech: [{ kind: "local", provider: "fixture-speech", account: "" }] });
        const runtime = path.join(process.env.JARVIS_TEST_ROOT, "r" + serial.toString(36));
        bridge = Bridge.create({ router, state: () => runner.state, audit, directory: runtime,
            clock: { set: () => ({}), clear() {} } });
        const a = account(script);
        let opened = null;
        // The adapter's timers run for real, or on the manual clock only when
        // a row fires them or advances past every armed one.
        const clock = { set: (fn, ms) => {
            const timer = { fn, ms, handle: setTimeout(() => { timer.fired = true; fn(); }, options.manual ? 1e9 : ms) };
            timers.push(timer);
            return timer;
        }, clear: timer => { timer.cleared = true; clearTimeout(timer.handle); } };
        const harness = ClaudeCode.create({ directory: a.directory, model: options.model ?? "", recipients,
            bridge: { open: async () => { opened = await bridge.open({ gen: runner.state.gen, recipients }); return opened; } },
            parent: runtime, environment: { ...process.env, ...PLANTED }, clock });
        owners.push(async () => { await harness.close(); bridge.close(); audit.close(); for (const timer of timers) clearTimeout(timer.handle); });
        harness.start({ instructions: "Fixture guidance.", tools: options.tools ?? router.offer() });
        const w = { runner, router, bridge, rows, starts, answers, brain, timers, harness, Policy, recipients, runtime, account: a,
            opened: () => opened, lock: value => { locked = value; }, time: value => { at = value; },
            advance: () => { for (const timer of timers) if (!timer.cleared && !timer.fired) { timer.fired = true; timer.fn(); } },
            show: () => runner.dispatch({ type: "shown", gen: runner.state.gen, op: runner.state.approval.op, id: runner.state.approval.id }),
            confirm: () => runner.dispatch({ type: "confirm", gen: runner.state.gen, id: runner.state.approval.id,
                digest: runner.state.approval.digest, source: "key" }) };
        w.say = text => harness.send({ kind: "user", items: [Policy.item(text, ["speech"])] });
        /** Read one turn to its end: {texts, reason}, or the adapter's own error. */
        const consume = async (reply, until = () => false) => {
            const texts = [];
            for (;;) {
                const step = await bounded(reply.events.next(), "harness event");
                if (step.done) assert.fail("events ended without done");
                if (step.value.kind === "done") return { texts, reason: step.value.reason };
                assert.equal(step.value.kind, "text");
                texts.push(step.value.text);
                if (until(texts)) return { texts, reason: null };
            }
        };
        // A turn expected to succeed turns any adapter failure into an assertion.
        w.read = (reply, until) => consume(reply, until).catch(error => {
            if (error instanceof assert.AssertionError) throw error;
            assert.fail("unexpected harness failure: " + error.message);
        });
        w.fails = async (reply, key) => {
            await assert.rejects(() => consume(reply), error => error.message === "jarvis: brain=" + key, key);
        };
        // Poll a condition the children reach across the event loop.
        w.until = async (predicate, what) => {
            for (let turn = 0; turn < 300; turn++) {
                if (predicate()) return;
                await new Promise(resolve => setTimeout(resolve, 10));
            }
            assert.fail(what + " never held");
        };
        return w;
    }
    async function cleanup() { while (owners.length) await owners.pop()(); }
    const say = text => [{ text }];

    const cases = [
        ["replay", async folder => {
            const w = await make(folder, { turns: [[...say("Hello. "), { echo: true }], [{ echo: true }]] });
            const first = w.say("open the window list");
            assert.deepEqual(first.release, { withheld: [], needed: [], labels: ["speech"] });
            assert.deepEqual(w.account.calls(), [], "nothing starts before the caller reads");
            assert.deepEqual(await w.read(first), { texts: ["Hello. ", "heard: open the window list"], reason: "stop" });
            assert.deepEqual(await w.read(w.say("again")), { texts: ["heard: again"], reason: "stop" });
            const calls = w.account.calls();
            assert.equal(calls.length, 1, "one program serves the conversation");
            const call = calls[0];
            const config = call.args[ARGV.indexOf("CONFIG")];
            assert.deepEqual(call.args, [...ARGV.map(arg => arg === "CONFIG" ? config : arg),
                "--system-prompt", "Fixture guidance."], "built-in tools off; only the bridge");
            assert.deepEqual(Object.keys(call.env).filter(name => !["PWD", "SHLVL", "_"].includes(name)).sort(), ENVIRONMENT);
            assert.equal(call.env.CLAUDE_CONFIG_DIR, w.account.directory);
            assert.equal(call.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, "1");
            assert.deepEqual(leaked(call), [], "no planted key, token or pid reaches the program");
            const token = w.opened().env.VGS_JARVIS_TOOLS_TOKEN;
            assert.equal(call.args.some(arg => arg.includes(token)), false, "the session token stays out of argv");
            assert.equal(path.dirname(config), path.dirname(call.cwd), "the config sits beside the private working directory");
            assert.equal(fs.statSync(path.dirname(config)).mode & 0o777, 0o700);
            assert.equal(fs.statSync(config).mode & 0o777, 0o600);
            assert.deepEqual(fs.readdirSync(call.cwd), []);
            assert.deepEqual(JSON.parse(fs.readFileSync(config, "utf8")), { mcpServers: { "vgs-jarvis": { type: "stdio",
                command: process.execPath, args: [path.join(folder, "mcp-shim")], env: w.opened().env } } });
            const inputs = w.account.events().filter(event => event.kind === "input").map(event => event.value);
            assert.deepEqual(inputs[0], { type: "user", message: { role: "user",
                content: [{ type: "text", text: "open the window list" }] }, parent_tool_use_id: null });
            assert.deepEqual(w.account.events().filter(event => event.kind === "refused"), []);
        }],
        ["gate", async folder => {
            const w = await make(folder, { turns: [[{ tool: "windows_list", arguments: {} }, ...say("Two windows.")]] });
            const reply = w.say("what is open");
            const done = w.read(reply);
            await w.until(() => w.starts.length === 1, "the executor start");
            assert.equal(w.starts[0].call.id, "windows.list");
            assert.deepEqual([w.starts[0].audit.kind, w.starts[0].audit.tool, w.starts[0].audit.decision, w.starts[0].audit.outcome],
                ["action", "windows.list", "allow", "pending"], "the gate audited the decision before the start");
            w.answers[0]({ outcome: "completed", content: "fixture windows" });
            assert.deepEqual(await done, { texts: ["Two windows."], reason: "stop" });
            const result = w.account.events().find(event => event.kind === "tool-result");
            assert.deepEqual(result.answer.result, { content: [{ type: "text", text: "fixture windows" }], isError: false });
            assert.deepEqual(w.brain, [], "the bridge, not the brain port, answers a harness call");
            assert.ok(w.rows().some(row => row.kind === "release" && row.decision === "send"), "the result passed release");
        }],
        ["approval", async folder => {
            const shell = { argv: ["fixture"], cwd: fixtures.project, network: false };
            const w = await make(folder, { turns: [[{ tool: "shell_argv", arguments: shell }, ...say("Ran it.")]] });
            const done = w.read(w.say("run the fixture"));
            await w.until(() => w.runner.state.approval.kind === "held", "the held approval");
            assert.equal(w.starts.length, 0, "nothing starts while held");
            assert.ok(w.rows().some(row => row.tool === "shell.argv" && row.decision === "confirm" && row.outcome === "pending"));
            w.show(); w.time(700); w.confirm();
            assert.equal(w.starts.length, 1);
            w.answers[0]({ outcome: "completed", content: "fixture ran" });
            assert.deepEqual(await done, { texts: ["Ran it."], reason: "stop" });
            assert.equal(w.account.events().find(event => event.kind === "tool-result").answer.result.isError, false);
        }],
        ["refusal", async folder => {
            const w = await make(folder, { turns: [[{ tool: "windows_list", arguments: {} }, ...say("Locked.")]] });
            w.lock(true);
            assert.deepEqual(await w.read(w.say("list windows")), { texts: ["Locked."], reason: "stop" });
            const answer = w.account.events().find(event => event.kind === "tool-result").answer.result;
            assert.deepEqual(answer, { content: [{ type: "text", text: JSON.stringify({ kind: "refuse", reason: "session-locked" }) }], isError: true });
            assert.equal(w.starts.length, 0);
        }],
        ["built-ins", async folder => {
            // The program's one irremovable built-in passes; a built-in call does not.
            const w = await make(folder, { endConversation: true, turns: [[...say("ok")], [{ builtin: "Bash" }]] });
            assert.deepEqual(await w.read(w.say("first")), { texts: ["ok"], reason: "stop" });
            await w.fails(w.say("second"), "harness-tool name=Bash");
            assert.throws(() => w.say("third"), /brain=harness-ended/, "a fault ends the conversation");
            const listed = await make(folder, { extraTools: ["Read"], turns: [[...say("never")]] });
            await listed.fails(listed.say("hello"), "harness-tool name=Read");
            const server = await make(folder, { failServer: true, turns: [[...say("never")]] });
            await server.fails(server.say("hello"), "harness-mcp");
            // Without an offer the irremovable built-in must be absent too.
            const bare = await make(folder, { endConversation: true, extraTools: ["EndConversation"], turns: [[...say("never")]] }, { tools: [] });
            await bare.fails(bare.say("hello"), "harness-tool name=EndConversation");
        }],
        ["cancel", async folder => {
            // Two texts in one read: the second is queued when the interrupt goes out.
            const w = await make(folder, { turns: [[{ texts: ["partial", "queued"] }, { hang: true }], [{ echo: true }]] },
                { manual: true });
            const reply = w.say("long answer");
            assert.deepEqual(await w.read(reply, texts => texts.length === 1), { texts: ["partial"], reason: null });
            // The caller reads on while the turn is cancelling.
            const cancelled = w.harness.cancel();
            await assert.rejects(() => bounded(reply.events.next(), "cancelled read"), /brain=cancelled/, "queued text never reaches the caller");
            await bounded(cancelled, "cancel acknowledgement");
            const interrupt = w.account.events().find(event => event.kind === "interrupt");
            assert.ok(interrupt, "the interrupt control request reached the program");
            const request = w.account.events().filter(event => event.kind === "input").at(-1).value;
            assert.deepEqual(request, { type: "control_request", request_id: interrupt.id, request: { subtype: "interrupt" } });
            assert.deepEqual(w.timers.map(timer => [timer.ms, timer.cleared === true]), [[2000, true]], "the answer disarms the bound");
            w.advance();
            assert.deepEqual(await w.read(w.say("next")), { texts: ["heard: next"], reason: "stop" });
            assert.equal(w.account.calls().length, 1, "the conversation keeps its program after an answered interrupt");
            // The turn ends before the program reads the interrupt: the answer
            // follows the result, between turns, and the conversation lives on.
            const race = await make(folder, { answerAfterResult: true, turns: [[...say("partial"), { hang: true }], [{ echo: true }]] },
                { manual: true });
            const raced = race.say("short answer");
            await race.read(raced, texts => texts.length === 1);
            await bounded(race.harness.cancel(), "raced cancel");
            await assert.rejects(() => raced.events.next(), /brain=cancelled/);
            let next;
            assert.doesNotThrow(() => { next = race.say("next"); }, "a late answer keeps the conversation");
            assert.deepEqual(await race.read(next), { texts: ["heard: next"], reason: "stop" });
            assert.equal(race.account.calls().length, 1, "the late answer keeps the program");
        }],
        ["cancel-timeout", async folder => {
            const w = await make(folder, { ignoreInterrupt: true, turns: [[{ hang: true }]] }, { manual: true });
            const reply = w.say("hang");
            const pending = reply.events.next().then(() => null, error => error);
            await w.until(() => w.account.events().some(event => event.kind === "input"), "the prompt");
            const cancelled = w.harness.cancel();
            await w.until(() => w.timers.length === 1, "the cancel timer");
            assert.equal(w.timers[0].ms, 2000);
            w.timers[0].fn();
            await bounded(cancelled, "cancel after the bound");
            assert.equal((await pending)?.message, "jarvis: brain=cancelled");
            assert.throws(() => w.say("next"), /brain=harness-ended/);
        }],
        ["results", async folder => {
            for (const [steps, key] of [
                [[{ result: "api-error" }], "harness-api-error status=429"],
                [[{ result: "error_max_turns" }], "harness-error-max-turns"],
                [[{ exit: 5 }], "harness-exit code=5"],
                [[{ raw: "not json" }], "harness-json"],
                [[{ raw: JSON.stringify({ type: "control_request", request_id: "x", request: { subtype: "can_use_tool" } }) }], "harness-control-request"],
                [[{ text: "nested", parent: "toolu_x" }], "harness-subagent"],
                [[{ control: "foreign" }], "harness-control"],
                [[{ raw: JSON.stringify({ type: "assistant", parent_tool_use_id: null, message: { role: "assistant",
                    content: [{ type: "server_tool_use", name: "web_search" }] } }) }], "harness-block type=server_tool_use"],
                [[{ raw: JSON.stringify({ type: "result", subtype: "unknown" }) }], "harness-result"]
            ]) {
                const w = await make(folder, { turns: [[...say("before"), ...steps]] });
                await w.fails(w.say("go"), key);
            }
            // Notices and thinking pass unread.
            const w = await make(folder, { turns: [[{ retry: true }, { thinking: true }, ...say("after")]] });
            assert.deepEqual(await w.read(w.say("go")), { texts: ["after"], reason: "stop" });
            // A reply before the init message names the tools is a harness fault.
            const early = await make(folder, { skipInit: true, turns: [[...say("x")]] });
            await early.fails(early.say("go"), "harness-order");
            // A reply while no turn is live ends the conversation.
            const late = await make(folder, { turns: [[{ result: "success", late: "stray" }]] });
            assert.deepEqual(await late.read(late.say("go")), { texts: [], reason: "stop" });
            assert.throws(() => late.say("again"), /brain=harness-ended/);
        }],
        ["release", async folder => {
            const w = await make(folder, { turns: [[{ echo: true }], [{ echo: true }]] });
            const file = w.Policy.item("fixture file body", ["file"]);
            const asked = w.harness.send({ kind: "user", items: [w.Policy.item("read it", ["speech"]), file] });
            assert.deepEqual(asked.release, { withheld: [], needed: ["file"], labels: ["speech"] });
            assert.deepEqual(await w.read(asked), { texts: ["heard: read it [withheld: file text]"], reason: "stop" });
            const granted = w.harness.send({ kind: "user", items: [file] }, [{ recipients: w.recipients, labels: ["file"] }]);
            assert.deepEqual(granted.release.labels, ["file"]);
            assert.deepEqual(await w.read(granted), { texts: ["heard: fixture file body"], reason: "stop" });
            const empty = await make(folder, { turns: [[{ echo: true }]] });
            const withheld = empty.harness.send({ kind: "user", items: [file] });
            await empty.fails(withheld, "release-empty");
            assert.deepEqual(empty.account.calls(), [], "a request with nothing released starts no program");
            assert.throws(() => w.harness.send({ kind: "tool-results", results: [] }), /brain=tool-results/);
        }],
        ["bounds", async folder => {
            // One output line at 1 MiB passes; one byte more ends the conversation.
            for (const [bytes, accepted] of [[1024 * 1024, true], [1024 * 1024 + 1, false]]) {
                const w = await make(folder, { turns: [[{ sized: bytes }]] });
                const reply = w.say("big");
                if (accepted) assert.equal((await w.read(reply)).texts[0].length > 1000000, true);
                else await w.fails(reply, "harness-line-limit");
            }
            // A line that never ends fails once it passes the line bound.
            const open = await make(folder, { turns: [[{ unterminated: 1024 * 1024 + 1 }]] });
            await open.fails(open.say("endless"), "harness-line-limit");
            // A turn's output, init, text lines and result with their newlines,
            // at exactly 8 MiB passes; one byte more fails at the result.
            for (const [bytes, accepted] of [[8 * 1024 * 1024, true], [8 * 1024 * 1024 + 1, false]]) {
                const w = await make(folder, { turns: [[{ fill: bytes }]] });
                const reply = w.say("many");
                if (accepted) assert.equal((await w.read(reply)).texts.length, 8);
                else await w.fails(reply, "harness-turn-limit");
            }
            // Forty user turns pass; the forty-first refuses before it is sent.
            const long = await make(folder, { turns: [[...say("ok")]] });
            for (let index = 0; index < 40; index++) await long.read(long.say("turn " + index));
            assert.throws(() => long.say("one more"), /brain=context-limit/);
            assert.throws(() => long.harness.start({ instructions: "", tools: [] }), /brain=started/);
            // A user turn's line at 20 MiB is accepted; one byte more refuses before anything is sent.
            const request = await make(folder, { turns: [[...say("ok")]] });
            const empty = JSON.stringify({ type: "user", message: { role: "user", content: [{ type: "text", text: "" }] }, parent_tool_use_id: null });
            const sized = bytes => request.Policy.item("x".repeat(bytes - Buffer.byteLength(empty)), ["speech"]);
            assert.throws(() => request.harness.send({ kind: "user", items: [sized(20 * 1024 * 1024 + 1)] }), /brain=request-limit/);
            let fitting;
            assert.doesNotThrow(() => { fitting = request.harness.send({ kind: "user", items: [sized(20 * 1024 * 1024)] }); });
            await bounded(fitting.events.return(), "unsent turn cancel");
            assert.deepEqual(request.account.calls(), [], "neither request started the program");
            // Sixty-four offered tools are accepted; sixty-five refuse.
            const ClaudeCode = require(path.join(folder, "ClaudeCode.js"));
            const offer = count => Array.from({ length: count }, (_, index) => ({ id: "fixture.t" + index }));
            const fresh = () => ClaudeCode.create({ directory: request.account.directory, recipients: request.recipients,
                bridge: { open: async () => assert.fail("no session opens") }, parent: request.runtime, environment: process.env });
            assert.doesNotThrow(() => fresh().start({ instructions: "", tools: offer(64) }));
            assert.throws(() => fresh().start({ instructions: "", tools: offer(65) }), /brain=tools/);
        }],
        ["close", async folder => {
            const w = await make(folder, { turns: [[...say("one")]] });
            await w.read(w.say("hello"));
            const call = w.account.calls()[0];
            const socket = w.opened().env.VGS_JARVIS_TOOLS_SOCKET;
            assert.ok(fs.existsSync(socket));
            await bounded(w.harness.close(), "close");
            assert.equal(fs.existsSync(path.dirname(call.cwd)), false, "the private working directory is removed");
            assert.equal(fs.existsSync(socket), false, "the bridge session closed with the conversation");
            assert.throws(() => w.say("after"), /brain=closed/);
            // A close while the bridge session opens closes that session.
            let opened, closedSessions = 0;
            const late = require(path.join(folder, "ClaudeCode.js")).create({ directory: account({ turns: [[]] }).directory,
                recipients: w.recipients, bridge: { open: () => new Promise(resolve => { opened = resolve; }) },
                parent: w.runtime, environment: process.env });
            late.start({ instructions: "", tools: w.router.offer() });
            const reply = late.send({ kind: "user", items: [w.Policy.item("hello", ["speech"])] });
            const outcome = reply.events.next().then(() => null, error => error.message);
            await w.until(() => opened !== undefined, "the session open");
            const closing = late.close();
            opened({ command: process.execPath, args: [], env: {}, close: () => { closedSessions++; } });
            assert.equal(await bounded(outcome, "the late turn"), "jarvis: brain=cancelled");
            await bounded(closing, "late close");
            assert.equal(closedSessions, 1, "the late session is closed");
        }]
    ];

    // Account Verify through the real judge: the harness handoff for a Claude
    // subscription, and the refusal every other subscription keeps.
    const env = { ...PLANTED };
    for (const name of ["PATH", "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_RUNTIME_DIR"]) env[name] = process.env[name];
    const state = path.join(process.env.XDG_STATE_HOME, "vgs/jarvis");
    const verifyAccount = account({ turns: [[...say("OK")]] }, path.join(process.env.HOME, ".claude-team"));
    const presence = Object.fromEntries(require(path.join(tree, "shell/plugins/vgs.jarvis/AccountProviders.js")).PROVIDERS
        .filter(row => row.kind === "key" || row.kind === "speech-key").map(row => [row.variable, false]));
    async function verify(folder, script) {
        fs.writeFileSync(path.join(verifyAccount.directory, "script.json"), JSON.stringify({ tree,
            auditDirectory: path.join(state, "audit"), ...script }));
        fs.rmSync(path.join(verifyAccount.directory, "events.jsonl"), { force: true });
        fs.mkdirSync(state, { recursive: true });
        const { Accounts } = require(path.join(folder, "Accounts.js"));
        const judge = new Accounts(state, env, presence);
        const chosen = judge.discover().find(row => row.source.kind === "cli" && row.source.directory === verifyAccount.directory);
        assert.ok(chosen, "discovery finds the Claude directory");
        return { judge, result: await bounded(judge.verify(chosen.id, "user"), "verify"), chosen };
    }
    cases.push(["verify", async folder => {
        const before = verifyAccount.calls().length;
        const { judge, result } = await verify(folder, { turns: [[...say("OK")]] });
        assert.deepEqual(result, { kind: "verified" });
        const call = verifyAccount.calls().slice(before).find(value => value.args[0] === "-p");
        const config = call.args[ARGV.indexOf("CONFIG")];
        assert.deepEqual(call.args, [...ARGV.map(arg => arg === "CONFIG" ? config : arg), "--system-prompt", "Answer in one word."]);
        assert.deepEqual(Object.keys(call.env).filter(name => !["PWD", "SHLVL", "_", ...ENVIRONMENT].includes(name)), []);
        assert.deepEqual(leaked(call), [], "no planted key, token or pid reaches the Verify program");
        const audit = verifyAccount.events().find(event => event.kind === "audit").last;
        assert.notEqual(audit, null, "an audit record exists when the vendor program starts");
        assert.deepEqual([audit.kind, audit.tool, audit.effect, audit.decision, audit.outcome],
            ["release", "release", "external", "send", "pending"], "the release is recorded before the vendor program starts");
        const input = verifyAccount.events().find(event => event.kind === "input").value;
        assert.deepEqual(input.message.content, [{ type: "text", text: "Reply OK." }]);
        assert.equal(fs.existsSync(path.dirname(call.cwd)), false, "the probe's working directory is removed");
        assert.equal(JSON.stringify(judge.status()).includes("OK"), false, "no reply text reaches status");
        for (const [script, reason] of [
            [{ turns: [[{ result: "success" }]] }, "no-inference"],
            [{ extraTools: ["Bash"], turns: [[...say("OK")]] }, "harness-tool"],
            [{ turns: [[{ result: "error_during_execution" }]] }, "harness-error-during-execution"],
            // Text proves nothing until the turn succeeds.
            [{ turns: [[...say("OK"), { result: "error_during_execution" }]] }, "harness-error-during-execution"],
            [{ turns: [[...say("OK"), { exit: 5 }]] }, "harness-exit"]
        ]) assert.deepEqual((await verify(folder, script)).result, { kind: "unavailable", reason }, reason);
        // A stalled program: at the deadline the conversation closes, its
        // process and directory go, and Verify fails keyed.
        const ClaudeCode = require(path.join(folder, "ClaudeCode.js")), Policy = require(path.join(folder, "Policy.js"));
        const stalled = account({ turns: [[{ hang: true }]] });
        const timers = [];
        const clock = { set: (fn, ms) => { const timer = { fn, ms }; timers.push(timer); return timer; },
            clear: timer => { timer.cleared = true; } };
        const recipients = Policy.recipients({ conversation: "verify-deadline", profile: "standard", cloudVision: "never",
            brain: { kind: "network", provider: "claude", account: "fixture", origin: "https://api.anthropic.com" },
            speech: [{ kind: "local", provider: "verification-result", account: "fixture" }] });
        const stalling = ClaudeCode.verify({ directory: stalled.directory, model: "", recipients, item: Policy.item("Reply OK.", ["command"]),
            grants: [{ recipients, labels: ["command"] }], parent: path.join(process.env.JARVIS_TEST_ROOT, "rv"), environment: env,
            instructions: "", deadline: 30000, clock, start: events => events.next() }).then(() => null, error => error.message);
        for (let tries = 0; tries < 300 && !stalled.events().some(event => event.kind === "input"); tries++)
            await new Promise(resolve => setTimeout(resolve, 10));
        assert.deepEqual(timers.map(timer => timer.ms), [30000], "one deadline, armed before the program answers");
        timers[0].fn();
        assert.equal(await bounded(stalling, "verify deadline"), "jarvis: brain=harness-timeout");
        // Close removes the directory only once the process is gone.
        assert.equal(fs.existsSync(path.dirname(stalled.calls()[0].cwd)), false, "the probe's working directory is removed");
        // Another vendor's subscription keeps its refusal; no program starts.
        const codex = { id: "codex-fixture", provider: "codex", label: "default", source: { kind: "cli", directory: verifyAccount.directory },
            state: { kind: "verifying", operation: 1 } };
        const calls = verifyAccount.calls().length;
        await assert.rejects(() => judge.inference(codex), /verify=subscription-handoff-unavailable/);
        assert.equal(verifyAccount.calls().length, calls);
    }]);

    const byName = name => cases.find(row => row[0] === name)[1];
    // An Accounts mutant loads ../AccountProviders.js beside its folder.
    fs.copyFileSync(path.join(tree, "shell/plugins/vgs.jarvis/AccountProviders.js"),
        path.join(process.env.JARVIS_TEST_ROOT, "AccountProviders.js"));
    try {
        for (const [name, check] of cases) {
            try { await check(backend); } finally { await cleanup(); }
            console.log("case=" + name + " passed");
        }
        const released = () => JSON.stringify(held()) === JSON.stringify(baseline);
        for (let tries = 0; tries < 200 && !released(); tries++) await new Promise(resolve => setTimeout(resolve, 10));
        assert.deepEqual(held(), baseline, "every harness, shim and bridge is gone after teardown");
        let controls = 0;
        const control = async (file, name, needle, replacement, row) => {
            await mutant(file, name, needle, replacement, async (_module, folder) => {
                try { await byName(row)(folder); } finally { await cleanup(); }
            }, path.basename(file));
            controls++;
            console.log("control=" + name + " detected");
        };
        for (const [name, needle, replacement, row] of [
            ["tools-off", '"--tools", "", ', "", "replay"],
            ["strict-mcp", '"--strict-mcp-config", ', "", "replay"],
            ["no-hooks", '"--settings", JSON.stringify({ disableAllHooks: true }),', "", "replay"],
            ["no-session-files", ', "--no-session-persistence"', "", "replay"],
            ["token-file", '"--mcp-config", config,', '"--mcp-config", fs.readFileSync(config, "utf8"),', "replay"],
            ["environment", "for (const name of ENVIRONMENT)", "for (const name of Object.keys(environment))", "replay"],
            ["environment-key", '"XDG_CACHE_HOME", "XDG_RUNTIME_DIR"];', '"XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "ANTHROPIC_API_KEY"];', "replay"],
            ["one-process", 'record = process_.kind === "running" ? process_ : await spawn();', "record = await spawn();", "replay"],
            ["init-tools", 'for (const name of init.tools) if (!allowed(name)) fail("harness-tool name=" + named(name));', "", "built-ins"],
            ["tool-use", 'if (block.kind === "tool" && !allowed(block.name)) fail("harness-tool name=" + named(block.name));', "", "built-ins"],
            ["mcp-server", 'servers.length !== 1 || servers[0].name !== SERVER || servers[0].status !== "connected"', "false", "built-ins"],
            ["end-conversation-scope", '(name === END_CONVERSATION && context.offered.size !== 0)', "name === END_CONVERSATION", "built-ins"],
            ["release", "const decision = Policy.release(item, recipients, grants);", "const decision = { kind: \"send\", ...item };", "release"],
            ["release-empty", 'if (request.release.labels.length === 0) fail("release-empty");', "", "release"],
            ["interrupt", "record.child.stdin.write(JSON.stringify({ type: \"control_request\"", "void (JSON.stringify({ type: \"control_request\"", "cancel"],
            ["interrupt-disarm", "if (timer !== null) { clock.clear(timer); timer = null; }", "if (false) { clock.clear(timer); timer = null; }", "cancel"],
            ["cancelled-text", 'case "cancelling": break;\n                    case "streaming":', 'case "cancelling":\n                    case "streaming":', "cancel"],
            ["late-answer", 'case "control": acknowledge(message); return;', 'case "control": fail("harness-order");', "cancel"],
            ["foreign-answer", 'if (!interrupts.delete(message.id)) fail("harness-control");', "interrupts.delete(message.id);", "results"],
            ["between-turns", 'default: fail("harness-order");', "default: return;", "results"],
            ["api-error", 'return value.is_error ? { kind: "result", outcome: "api-error",', 'return false ? { kind: "result", outcome: "api-error",', "results"],
            ["block-type", 'default: return fail("harness-block type=" + named(block.type));', 'default: return { kind: "thinking" };', "results"],
            ["control-request", 'case "control-request": return fail("harness-control-request");', 'case "control-request": return;', "results"],
            ["init-order", 'if (!record.initialized) fail("harness-order");', "", "results"],
            ["cancel-bound", "const CANCEL_MS = 2000;", "const CANCEL_MS = 2001;", "cancel"],
            ["cancel-timer", 'timer = clock.set(() => { timer = null; fault(record, new Error("jarvis: brain=harness-cancel-timeout")); }, CANCEL_MS);', "", "cancel-timeout"],
            ["subagent", 'if (value.parent_tool_use_id !== null) fail("harness-subagent");', "", "results"],
            ["result-error", 'if (RESULT_ERRORS.includes(value.subtype)) return { kind: "result", outcome: value.subtype };',
                'if (RESULT_ERRORS.includes(value.subtype)) return { kind: "result", outcome: "success" };', "results"],
            ["line-raised", "const LINE_BYTES = 1024 * 1024;", "const LINE_BYTES = 1024 * 1024 + 1;", "bounds"],
            ["line-lowered", "const LINE_BYTES = 1024 * 1024;", "const LINE_BYTES = 1024 * 1024 - 1;", "bounds"],
            ["line-tail", 'if (Buffer.byteLength(tail) > LINE_BYTES) fault(record, new Error("jarvis: brain=harness-line-limit"));', "", "bounds"],
            ["turn-raised", "const TURN_BYTES = 8 * 1024 * 1024;", "const TURN_BYTES = 8 * 1024 * 1024 + 1;", "bounds"],
            ["turn-lowered", "const TURN_BYTES = 8 * 1024 * 1024;", "const TURN_BYTES = 8 * 1024 * 1024 - 1;", "bounds"],
            ["context-bound", "const TURNS = 40;", "const TURNS = 41;", "bounds"],
            ["request-bound", "const REQUEST_BYTES = 20 * 1024 * 1024;", "const REQUEST_BYTES = 20 * 1024 * 1024 - 1;", "bounds"],
            ["tools-bound", "const TOOLS = 64;", "const TOOLS = 65;", "bounds"],
            ["close-bridge", "        launch?.close();\n        let exited", "        let exited", "close"],
            ["close-late-session", "if (closing !== null) { launch?.close(); fail(\"closed\"); }", "if (closing !== null) fail(\"closed\");", "close"],
            ["close-again", "if (closing !== null) return closing;", "if (closing !== null) return Promise.resolve();", "verify"],
            ["close-workdir", "if (workdir !== null) fs.rmSync(workdir, { recursive: true, force: true });", "", "close"],
            ["verify-result", 'if (step.value.kind === "text") text += step.value.text;', 'if (step.value.kind === "text") return step.value.text;', "verify"],
            ["verify-deadline", "const timer = clock.set(() => { expired = true; void brain.close(); }, deadline);",
                "const timer = clock.set(() => { expired = true; }, deadline);", "verify"]
        ]) await control(harnessFile, name, needle, replacement, row);
        for (const [name, needle, replacement] of [
            ["verify-route", 'if (row.id !== "claude") fail("verify=subscription-handoff-unavailable");', ""],
            ["verify-audit", "start: events => release.start(() => events.next())", "start: events => events.next()"],
            ["verify-text", '}).then(text => text.trim() !== ""));', "}).then(() => true));"],
            ["verify-reason", "harness ? harness[1] : ", ""]
        ]) await control(accountsFile, name, needle, replacement, "verify");
        console.log("test-jarvis-claude: ok cases=" + cases.length + " controls=" + controls);
        // A control that removes close leaves its mutant child running; the
        // check above already proved the real owner's teardown.
        process.exit(0);
    } finally { await cleanup(); }
}, standins => {
    fs.copyFileSync(stub, path.join(standins, "claude"));
    fs.chmodSync(path.join(standins, "claude"), 0o700);
})?.catch(error => { console.error(error); process.exitCode = 1; });
