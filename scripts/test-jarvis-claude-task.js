#!/usr/bin/env node
// Synthetic Claude Code task cases from AgentProfiles.js, claude-hook and
// TaskRelay.js v1, 2026-10-02. The stand-in claude,
// scripts/fixtures/jarvis-claude/claude-task.js, runs the hooks --settings
// wires as the Claude Code hooks reference describes; TaskRunner, task-run.py
// and the task engine copy are real. Everything runs inside the J09 world.
// No vendor program, login, terminal, network or live session. Every signal
// targets a group this suite recorded, never a name.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const { once } = require("node:events");
const tree = path.resolve(__dirname, "..");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
// The files a control copies: the engine copy's four and their consumers.
const ENGINE = ["Tasks.js", "task-event", "TaskRelay.js", "claude-hook"];
const SOURCES = ENGINE.concat(["TaskRunner.js", "AgentProfiles.js", "task-run.py"]);
const EVENTS = ["Notification", "PermissionRequest", "SessionEnd", "Stop", "StopFailure", "UserPromptSubmit"];
// Hook timeouts in seconds: a held event's is the 600 s window plus 60.
const TIMEOUTS = { UserPromptSubmit: 30, Notification: 30, PermissionRequest: 660, Stop: 660, StopFailure: 30, SessionEnd: 10 };

async function inside() {
    const root = process.env.JARVIS_TEST_ROOT;
    const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" };
    const Tasks = require(path.join(backend, "Tasks.js"));
    const groups = new Set();
    const launchers = [];
    let cases = 0, controls = 0, worlds = 0;

    // Real processes cross exec, pipes, the producer's lock and the relay's
    // poll. Bound each wait.
    async function until(label, predicate, ms = 15000) {
        const deadline = Date.now() + ms;
        for (;;) {
            const value = await predicate();
            if (value) return value;
            if (Date.now() > deadline) assert.fail("timeout: " + label);
            await sleep(20);
        }
    }
    const load = dir => ({ dir, Runner: require(path.join(dir, "TaskRunner.js")),
        Profiles: require(path.join(dir, "AgentProfiles.js")), Relay: require(path.join(dir, "TaskRelay.js")),
        Tasks: require(path.join(dir, "Tasks.js")) });
    const kinds = record => record.events.map(event => event.kind === "wait" ? "wait " + event.data.kind
        : event.kind === "turn-failed" ? "turn-failed " + event.data.kind : event.kind);

    // One world: private state and runtime directories with a quote and a
    // space, an engine published from a snapshot of modules.dir that is then
    // removed, an account directory, and a runner whose floating display runs
    // task-run.py in a session of its own.
    function world(modules) {
        const base = path.join(root, "w" + (++worlds));
        const directories = { state: path.join(base, "it's \"state\""), runtime: path.join(base, "run time") };
        const snapshot = path.join(base, "snapshot");
        fs.mkdirSync(snapshot, { recursive: true });
        for (const file of ENGINE) fs.copyFileSync(path.join(modules.dir, file), path.join(snapshot, file));
        const engine = modules.Tasks.publish(path.join(base, "data"), snapshot);
        fs.rmSync(snapshot, { recursive: true });
        const account = path.join(base, "accounts", ".claude-work");
        fs.mkdirSync(account, { recursive: true });
        const prompts = path.join(directories.runtime, "prompts");
        const seen = { launchers: [], faults: [] };
        let runner = null;
        runner = modules.Runner.create({ directories, engine, backend: modules.dir,
            settings: () => ({ taskTerminal: "floating" }),
            display: { run(args) {
                const child = cp.spawn("python3", [path.join(modules.dir, "task-run.py"), "--spec", args[0]],
                    { env, stdio: ["ignore", "pipe", "pipe"], detached: true });
                const entry = { child, stderr: "", closed: once(child, "close") };
                child.stderr.on("data", chunk => { entry.stderr += chunk; });
                child.on("close", () => runner.tuiState(false));
                seen.launchers.push(entry);
                launchers.push(child);
                runner.tuiState(true);
                return Promise.resolve("ok");
            } },
            count() {}, failed: error => seen.faults.push(error.message),
            accounts: (agent, reference) => agent === "claude" && reference === "cli:work" ? account : null,
            environment: { ...env, XDG_RUNTIME_DIR: path.join(base, "xdg"), VGSH_RUNNER_PID: "1", FIXTURE_SECRET: "x" },
            lookup: command => command === "claude",
            clock: { now: Date.now, set: setTimeout, clear: clearTimeout } });
        runner.tuiState(false);
        const read = id => new Tasks.Store(directories.state).read(id);
        const log = () => fs.readFileSync(path.join(account, "log.jsonl"), "utf8").trim().split("\n").map(line => JSON.parse(line));
        async function start(script, args = {}) {
            fs.writeFileSync(path.join(account, "script.json"), JSON.stringify(script));
            const answer = await new Promise(resolve => runner.executor(async () => "send").start(Object.freeze({
                id: "task.start", args: { goal: "Fix the build", cwd: path.join(root, "home"), agent: "claude", account: "cli:work", ...args }
            }), resolve));
            const result = JSON.parse(answer.content);
            return { answer, result };
        }
        async function started(script) {
            const { answer, result } = await start(script);
            assert.equal(answer.outcome, "completed", answer.content);
            const task = await until("started", () => {
                const record = read(result.task);
                return record.process.kind !== "starting" && record;
            });
            if (task.identity !== null) groups.add(task.identity.pgid);
            return result.task;
        }
        // The one prompt the task's hook holds, once it is published.
        const prompt = (id, kind) => until("held " + kind, () => {
            const held = runner.held().filter(item => item.task === id);
            assert.ok(held.length <= 1, "one prompt at a time");
            return held.length === 1 && held[0].kind === kind && held[0];
        });
        function close() {
            runner.close();
            assert.deepEqual(seen.faults, [], "the runner reported no fault");
        }
        return { runner, directories, engine, prompts, account, seen, read, log, start, started, prompt, close };
    }

    function hook(engine, args, input) {
        const begun = Date.now();
        const result = cp.spawnSync(process.execPath, [path.join(path.dirname(engine), "claude-hook"), ...args],
            { env, input: typeof input === "string" ? input : JSON.stringify(input), encoding: "utf8", timeout: 20000 });
        assert.equal(result.error, undefined);
        return { ...result, ms: Date.now() - begun };
    }
    function hookAsync(engine, args, input) {
        const child = cp.spawn(process.execPath, [path.join(path.dirname(engine), "claude-hook"), ...args], { env });
        let stdout = "", stderr = "";
        child.stdout.on("data", chunk => { stdout += chunk; });
        child.stderr.on("data", chunk => { stderr += chunk; });
        child.stdin.end(JSON.stringify(input));
        return once(child, "close").then(([status, signal]) => ({ status, signal, stdout, stderr }));
    }
    function create(w, id) {
        const result = cp.spawnSync(process.execPath, [w.engine, "--state", w.directories.state, id, "create"],
            { env, input: JSON.stringify({ goal: "Fix the build", cwd: path.join(root, "home"), agent: "claude", account: "" }),
                encoding: "utf8", timeout: 10000 });
        assert.equal(result.status, 0, result.stderr);
    }
    const hookArgs = (w, id, event, window = "1000") =>
        ["--state", w.directories.state, "--prompts", w.prompts, "--window", window, id, event];
    const input = (event, fields = {}) => ({ session_id: "s", transcript_path: "/t", cwd: root, hook_event_name: event, ...fields });

    // The profile row and the --settings it builds, read independently of
    // the builder: one exec-form command hook per documented event.
    function profile(modules) {
        const { Profiles } = modules;
        assert.deepEqual(Object.keys(Profiles.TABLE), ["claude"]);
        const row = Profiles.TABLE.claude;
        assert.deepEqual([row.program, row.account, row.interrupt], ["claude", { variable: "CLAUDE_CONFIG_DIR" }, { signal: "SIGINT" }]);
        const brief = Profiles.brief({ goal: "-p --dangerously-skip-permissions", engine: "/data/engine/h/task-event",
            state: "/state", id: "t1" });
        assert.ok(!brief.startsWith("-"), "a goal that starts with - never leads the positional prompt");
        const argv = Profiles.command(row, { id: "t1", brief, cwd: "/work", account: "/acct", engine: "/data/engine/h/task-event",
            state: "/st ate", prompts: "/run/prompts", node: "/usr/bin/node" });
        assert.deepEqual([argv.length, argv[0], argv[1], argv[3]], [4, "claude", "--settings", brief]);
        const settings = JSON.parse(argv[2]);
        assert.deepEqual(Object.keys(settings), ["hooks"]);
        assert.deepEqual(Object.keys(settings.hooks).sort(), EVENTS);
        for (const event of EVENTS) {
            assert.deepEqual(settings.hooks[event], [{ hooks: [{ type: "command", command: "/usr/bin/node",
                timeout: TIMEOUTS[event], args: ["/data/engine/h/claude-hook", "--state", "/st ate", "--prompts", "/run/prompts",
                    "--window", "600000", "t1", event] }] }], event);
        }
        cases += 3;
    }

    // Permission and question relay end to end: the stand-in runs the wired
    // hooks; the user's answers reach them only through runner.answer.
    async function relay(modules) {
        const w = world(modules);
        const id = await w.started([
            { hook: "UserPromptSubmit", input: { prompt: "brief" } },
            { hook: "PermissionRequest", input: { tool_name: "Bash", tool_input: { command: "make test" } } },
            { hook: "Stop", input: { stop_hook_active: false, last_assistant_message: "Which branch should I use?" } },
            { report: "reported-ok" },
            { hook: "Stop", input: { stop_hook_active: true, last_assistant_message: "Done." } },
            { hook: "Notification", input: { notification_type: "idle_prompt", message: "waiting" } },
            { hook: "SessionEnd", input: { reason: "other" } }
        ]);
        const asked = await w.prompt(id, "permission");
        assert.deepEqual([asked.tool, asked.text], ["Bash", 'Bash {"command":"make test"}']);
        assert.equal(w.read(id).wait.kind, "permission");
        assert.equal(w.runner.answer(id, asked.id, { v: 1, kind: "reply", text: "yes" }), "answer-invalid");
        assert.equal(w.runner.answer(id, asked.id, { v: 1, kind: "allow" }), "answered");
        const question = await w.prompt(id, "question");
        assert.equal(question.text, "Which branch should I use?");
        assert.deepEqual([w.read(id).turn.kind, w.read(id).wait.kind], ["turn-ended", "question"]);
        assert.equal(w.runner.answer(id, question.id, { v: 1, kind: "reply", text: "main" }), "answered");
        // After the outcome is reported, a turn end holds nothing.
        await until("agent exit", () => {
            assert.deepEqual(w.runner.held(), [], "no prompt is held after the outcome is reported");
            return w.read(id).process.kind === "exited";
        });
        await w.seen.launchers[0].closed;
        const entries = w.log();
        const { settings, env: agentEnv } = entries[0].start;
        assert.equal(agentEnv.CLAUDE_CONFIG_DIR, w.account);
        for (const name of ["VGSH_RUNNER_PID", "FIXTURE_SECRET"]) assert.equal(Object.hasOwn(agentEnv, name), false, name);
        for (const event of EVENTS) {
            const args = settings.hooks[event][0].hooks[0].args;
            assert.equal(args[0], path.join(path.dirname(w.engine), "claude-hook"), "hooks run from the engine copy");
            assert.equal(fs.existsSync(args[0]), true);
        }
        const hooks = entries.slice(1);
        assert.deepEqual(hooks.map(entry => [entry.event, entry.status, entry.signal]),
            ["UserPromptSubmit", "PermissionRequest", "Stop", "Stop", "Notification", "SessionEnd"].map(event => [event, 0, null]),
            JSON.stringify(hooks.map(entry => entry.stderr)));
        assert.deepEqual(hooks.map(entry => entry.stdout === "" ? "" : JSON.parse(entry.stdout)), [
            "",
            { hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } } },
            { decision: "block", reason: "The user answered: main" },
            "", "", ""
        ]);
        const record = w.read(id);
        assert.deepEqual(kinds(record), ["started", "wait none", "working", "wait permission", "wait none", "turn-ended",
            "wait question", "wait none", "working", "outcome", "turn-ended", "wait idle", "wait none", "exited"]);
        assert.deepEqual([record.outcome.kind, record.state], ["reported-ok", "reported-ok"]);
        assert.deepEqual(fs.readdirSync(w.prompts), [], "every prompt leaves with its hook");
        w.close();
        cases++;
    }

    // A denied permission, failed turns and the notification map.
    async function deny(modules) {
        const w = world(modules);
        const id = await w.started([
            { hook: "Notification", input: { notification_type: "permission_prompt", message: "m" } },
            { hook: "PermissionRequest", input: { tool_name: "Edit", tool_input: { file_path: "/x" } } },
            { hook: "StopFailure", input: { error: "rate_limit", last_assistant_message: "API Error" } },
            { hook: "Notification", input: { notification_type: "elicitation_dialog", message: "m" } },
            { hook: "Notification", input: { notification_type: "auth_success", message: "m" } },
            { hook: "StopFailure", input: { error: "a-new-kind" } }
        ]);
        const asked = await w.prompt(id, "permission");
        assert.equal(w.runner.answer(id, asked.id, { v: 1, kind: "deny" }), "answered");
        await until("agent exit", () => w.read(id).process.kind === "exited");
        await w.seen.launchers[0].closed;
        const hooks = w.log().slice(1);
        assert.deepEqual(JSON.parse(hooks[1].stdout), { hookSpecificOutput: { hookEventName: "PermissionRequest",
            decision: { behavior: "deny", message: "The user denied this request." } } });
        assert.deepEqual(hooks.map(entry => entry.status), [0, 0, 0, 0, 0, 0]);
        assert.deepEqual(kinds(w.read(id)), ["started", "wait permission", "wait permission", "wait none",
            "turn-failed rate_limit", "wait question", "turn-failed unknown", "exited"]);
        assert.equal(w.read(id).state, "failed");
        w.close();
        cases++;
    }

    // No answer inside the window: no decision, so the agent asks in its own
    // terminal, the wait stays recorded and a late answer finds no prompt.
    async function expiry(modules) {
        const w = world(modules);
        for (const [event, fields, wait] of [
            ["PermissionRequest", { tool_name: "Bash", tool_input: {} }, "permission"],
            ["Stop", { stop_hook_active: false, last_assistant_message: "Shall I?" }, "question"]
        ]) {
            const id = "expiry-" + event;
            create(w, id);
            const running = hookAsync(w.engine, hookArgs(w, id, event), input(event, fields));
            const held = await w.prompt(id, wait);
            const result = await running;
            assert.deepEqual([result.status, result.stdout], [0, ""], result.stderr);
            assert.equal(w.read(id).wait.kind, wait);
            const late = wait === "permission" ? { v: 1, kind: "allow" } : { v: 1, kind: "reply", text: "x" };
            assert.equal(w.runner.answer(id, held.id, late), "prompt-unknown");
            assert.deepEqual(fs.readdirSync(w.prompts), []);
            cases++;
        }
        w.close();
    }

    // A full relay holds nothing; expired prompts a killed hook left are
    // swept, so they never fill it.
    async function full(modules) {
        const w = world(modules);
        create(w, "full");
        const now = Date.now();
        for (let i = 0; i < modules.Relay.MAX_PROMPTS; i++)
            modules.Relay.ask(w.prompts, "other", { kind: "question", tool: null, text: "q" }, now, 600000);
        const refused = hook(w.engine, hookArgs(w, "full", "PermissionRequest"), input("PermissionRequest", { tool_name: "Bash" }));
        assert.deepEqual([refused.status, refused.stdout], [0, ""], refused.stderr);
        assert.ok(refused.ms < 1000, "a full relay holds nothing");
        assert.equal(w.read("full").wait.kind, "permission");
        for (const name of fs.readdirSync(w.prompts)) fs.rmSync(path.join(w.prompts, name));
        for (let i = 0; i < modules.Relay.MAX_PROMPTS; i++)
            modules.Relay.ask(w.prompts, "other", { kind: "question", tool: null, text: "q" }, now - 700000, 1000);
        const running = hookAsync(w.engine, hookArgs(w, "full", "PermissionRequest", "5000"), input("PermissionRequest", { tool_name: "Bash" }));
        const held = await w.prompt("full", "permission");
        assert.equal(w.runner.answer("full", held.id, { v: 1, kind: "allow" }), "answered");
        const result = await running;
        assert.equal(JSON.parse(result.stdout).hookSpecificOutput.decision.behavior, "allow", result.stderr);
        assert.deepEqual(fs.readdirSync(w.prompts), [], "expired prompts were swept");
        w.close();
        cases += 2;
    }

    // A failing hook gives no decision and exits 1: never 2, which Claude
    // Code reads as a block on Stop and UserPromptSubmit.
    function failures(modules) {
        const w = world(modules);
        create(w, "fails");
        const file = path.join(root, "not-a-directory");
        fs.writeFileSync(file, "");
        const rows = [
            ["record", [...hookArgs(w, "fails", "Stop").slice(0, 1), file, ...hookArgs(w, "fails", "Stop").slice(2)],
                input("Stop"), /^jarvis: claude-hook=record kind=turn-ended /],
            ["permission-record", [...hookArgs(w, "fails", "PermissionRequest").slice(0, 1), file,
                ...hookArgs(w, "fails", "PermissionRequest").slice(2)], input("PermissionRequest", { tool_name: "Bash" }),
                /^jarvis: claude-hook=record kind=wait /],
            ["event", hookArgs(w, "fails", "PermissionRequest"), input("Stop"), /^jarvis: claude-hook=input-event event=PermissionRequest$/],
            ["json", hookArgs(w, "fails", "Stop"), "{", /^jarvis: claude-hook=input-json$/],
            ["window", hookArgs(w, "fails", "Stop", "999"), input("Stop"), /^jarvis: claude-hook=arguments$/],
            ["tool", hookArgs(w, "fails", "PermissionRequest"), input("PermissionRequest", { tool_name: "a b" }), /^jarvis: claude-hook=input-tool$/],
            ["unknown-event", hookArgs(w, "fails", "PreToolUse"), input("PreToolUse"), /^jarvis: claude-hook=arguments$/]
        ];
        for (const [name, args, value, stderr] of rows) {
            const result = hook(w.engine, args, value);
            assert.deepEqual([result.status, result.stdout], [1, ""], name);
            assert.match(result.stderr.trim(), stderr, name);
            assert.equal(result.stderr.trim().split("\n").length, 1, name);
            cases++;
        }
        assert.deepEqual(kinds(w.read("fails")), [], "a refused hook records nothing");
        w.close();
    }

    // The answer judge, through the daemon's port.
    function answers(modules) {
        const w = world(modules);
        const { Relay } = modules;
        assert.deepEqual(w.runner.held(), [], "no relay directory yet");
        const now = Date.now();
        const permission = Relay.ask(w.prompts, "t1", { kind: "permission", tool: "Bash", text: "Bash {}" }, now, 600000);
        const question = Relay.ask(w.prompts, "t1", { kind: "question", tool: null, text: "q\u0007?" }, now + 1, 600000);
        assert.equal(question.text, "q ?", "control characters are not kept");
        assert.equal(fs.statSync(w.prompts).mode & 0o777, 0o700);
        for (const name of fs.readdirSync(w.prompts)) assert.equal(fs.statSync(path.join(w.prompts, name)).mode & 0o777, 0o600);
        assert.deepEqual(w.runner.held().map(item => item.id), [permission.id, question.id]);
        const invalid = [
            [permission, { v: 1, kind: "reply", text: "yes" }], [permission, { v: 2, kind: "allow" }],
            [permission, { v: 1, kind: "allow", extra: 1 }], [permission, null], [permission, "allow"],
            [question, { v: 1, kind: "allow" }], [question, { v: 1, kind: "reply", text: "" }],
            [question, { v: 1, kind: "reply", text: "  " }], [question, { v: 1, kind: "reply", text: "a\u0007" }],
            [question, { v: 1, kind: "reply", text: "x".repeat(Relay.MAX_TEXT + 1) }]
        ];
        for (const [prompt, value] of invalid)
            assert.equal(w.runner.answer("t1", prompt.id, value), "answer-invalid", JSON.stringify(value)?.slice(0, 60));
        assert.equal(w.runner.answer("t2", permission.id, { v: 1, kind: "allow" }), "prompt-unknown");
        assert.equal(w.runner.answer("t1", "../" + permission.id, { v: 1, kind: "allow" }), "prompt-unknown");
        assert.equal(w.runner.answer("t1", permission.id, { v: 1, kind: "allow" }), "answered");
        assert.equal(w.runner.answer("t1", permission.id, { v: 1, kind: "deny" }), "answered-already");
        assert.deepEqual(Relay.answerTo(w.prompts, permission), { v: 1, kind: "allow" });
        assert.deepEqual(w.runner.held().map(item => item.id), [question.id], "an answered prompt is not asked again");
        assert.equal(Relay.answer(w.prompts, "t1", question.id, { v: 1, kind: "reply", text: "x" }, question.deadline), "prompt-expired");
        assert.deepEqual(Relay.pending(w.prompts, question.deadline).map(item => item.id), []);
        w.close();
        cases += invalid.length + 6;
    }

    // An account is a discovered one; anything else is refused before a record.
    async function account(modules) {
        const w = world(modules);
        const { answer, result } = await w.start([], { account: "/home/user/.claude" });
        assert.deepEqual([answer.outcome, result.reason], ["failed", "task-account-unknown"]);
        assert.deepEqual(fs.existsSync(path.join(w.directories.state, "tasks"))
            ? fs.readdirSync(path.join(w.directories.state, "tasks")).filter(name => !name.startsWith(".")) : [], []);
        w.close();
        cases++;
    }

    const current = load(backend);
    profile(current);
    await relay(current);
    await deny(current);
    await expiry(current);
    await full(current);
    failures(current);
    answers(current);
    await account(current);

    async function control(name, file, needle, replacement, check) {
        const source = fs.readFileSync(path.join(backend, file), "utf8");
        assert.equal(source.split(needle).length - 1, 1, name + " match");
        const changed = source.replace(needle, replacement);
        assert.notEqual(changed, source);
        const copy = path.join(root, "control-" + name);
        fs.mkdirSync(copy);
        for (const entry of SOURCES) fs.copyFileSync(path.join(backend, entry), path.join(copy, entry));
        fs.writeFileSync(path.join(copy, file), changed);
        await assert.rejects(async () => check(load(copy)), error => {
            assert.ok(error instanceof assert.AssertionError, name + " must turn red, not crash: " + error.stack);
            console.log("test-jarvis-claude-task: control=" + name + " killed by=" + JSON.stringify(error.message.split("\n")[0]));
            return true;
        });
        // A mutant can leave a held hook or a running stand-in: end every
        // group this suite recorded, by its recorded pgid.
        for (const pgid of groups) try { process.kill(-pgid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
        for (const child of launchers) if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
        controls++;
    }
    await control("exec-form", "AgentProfiles.js", "hooks: [{ type: \"command\", command: task.node, timeout,\n            args: [hook,",
        "hooks: [{ type: \"command\", command: task.node, timeout,\n            argv: [hook,", profile);
    await control("brief-lead", "AgentProfiles.js", 'return "The user asks, through Jarvis:\\n" + goal', "return goal", profile);
    await control("prompt-submit-silent", "claude-hook", '        record(hook, "working");\n        return null;\n    case "Notification"',
        '        record(hook, "working");\n        return {};\n    case "Notification"', relay);
    await control("permission-held", "claude-hook",
        "    const prompt = Relay.ask(hook.prompts, hook.task, detail, Date.now(), hook.window);",
        '    if (detail.kind === "permission") return { v: 1, kind: "allow" };\n    const prompt = Relay.ask(hook.prompts, hook.task, detail, Date.now(), hook.window);', relay);
    await control("deny", "claude-hook", 'decision: { behavior: "deny", message', 'decision: { behavior: "allow", message', deny);
    await control("stop-outcome", "claude-hook", 'if (task.outcome.kind !== "none") return null;', "if (false) return null;", relay);
    await control("stop-working", "claude-hook", '    record(hook, "working");\n    return { decision: "block"',
        '    return { decision: "block"', relay);
    await control("failure-kind", "claude-hook", "FAILURES.includes(value.error) ? value.error : \"unknown\"", '"unknown"', deny);
    await control("notification-map", "claude-hook", 'idle_prompt: "idle"', 'idle_prompt: "question"', relay);
    await control("expiry-silent", "claude-hook", "if (Date.now() >= prompt.deadline) return null;",
        'if (Date.now() >= prompt.deadline) return { v: 1, kind: "deny" };', expiry);
    await control("exit-code", "claude-hook", "    process.exitCode = 1;\n", "    process.exitCode = 2;\n", failures);
    await control("engine-copy", "Tasks.js", '"TaskRelay.js", "claude-hook"];', '"TaskRelay.js"];', relay);
    await control("answer-once", "TaskRelay.js", "fs.linkSync(temporary, answerFile(directory, task, id));",
        "fs.renameSync(temporary, answerFile(directory, task, id));", answers);
    await control("answer-kind", "TaskRelay.js", 'shape(value, ["v", "kind"]) && value.v === 1 && ["allow", "deny"].includes(value.kind)',
        "value !== null && typeof value === \"object\" && value.v === 1", answers);
    await control("answer-expired", "TaskRelay.js", 'if (prompt.deadline <= now) return "prompt-expired";',
        "if (false) return \"prompt-expired\";", answers);
    await control("pending-answered", "TaskRelay.js", "item.deadline > now && !fs.existsSync(answerFile(directory, item.task, item.id))",
        "item.deadline > now", answers);
    await control("relay-full", "TaskRelay.js", "if (live.length >= MAX_PROMPTS) return null;", "if (false) return null;", full);
    await control("relay-sweep", "TaskRelay.js", "        if (item.deadline <= now) withdraw(directory, item);\n        else live.push(item);",
        "        live.push(item);", full);
    await control("account", "TaskRunner.js", 'if (value === null) return { reason: "account-unknown" };',
        'if (false) return { reason: "account-unknown" };', account);
    console.log("test-jarvis-claude-task: ok cases=" + cases + " controls=" + controls);
}

function main() {
    // A failed case can leave held hooks and launchers alive; end at once.
    if (process.argv[2] === "--inside") return inside().catch(error => { console.error(error); process.exit(1); });
    const parent = path.join(tree, "tmp");
    fs.mkdirSync(parent, { recursive: true });
    const root = fs.realpathSync(fs.mkdtempSync(path.join(parent, "jct-")));
    try {
        const standins = path.join(root, "standins");
        fs.mkdirSync(standins);
        fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis-claude/claude-task.js"), path.join(standins, "claude"));
        fs.chmodSync(path.join(standins, "claude"), 0o755);
        const result = cp.spawnSync("/bin/bash", [path.join(tree, "scripts/lib/jarvis-env.sh"), standins,
            "--", "node", __filename, "--inside"], {
            env: { PATH: "/usr/bin:/bin", HOME: root, JARVIS_TEST_SCRATCH_ROOT: path.join(tree, "tmp") },
            encoding: "utf8", timeout: 600000
        });
        process.stdout.write(result.stdout || "");
        process.stderr.write(result.stderr || "");
        if (result.error) throw result.error;
        assert.equal(result.signal, null);
        process.exitCode = result.status;
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
try { main(); } catch (error) { console.error(error); process.exitCode = 1; }
