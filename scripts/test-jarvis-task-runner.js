#!/usr/bin/env node
// Synthetic task-runner cases from TaskRunner.js and task-run.py v1,
// 2026-10-01. Real task-run.py, real signals, the fixture agent
// scripts/fixtures/jarvis/task-agent.py and tmux on a private -S socket, all
// inside the J09 world. No vendor agent, account, terminal, network or live
// session. Every signal targets a group this suite recorded, never a name.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const { once } = require("node:events");
const { seedTaskEvents } = require("./fixtures/jarvis/prepare.js");
const tree = path.resolve(__dirname, "..");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function spawnFixture(file, args, { env, input }) {
    return new Promise((resolve, reject) => {
        const child = cp.spawn(file, args, { env, stdio: ["pipe", "pipe", "pipe"] });
        let stdout = "", stderr = "";
        child.stdout.on("data", chunk => { stdout += chunk; });
        child.stderr.on("data", chunk => { stderr += chunk; });
        // A refused terminal can exit without reading. Its status remains the answer.
        child.stdin.on("error", error => { if (error.code !== "EPIPE") reject(error); });
        child.on("error", reject);
        child.on("close", (code, signal) => resolve({ code, signal, stdout, stderr }));
        child.stdin.end(input);
    });
}

async function inside() {
    const root = process.env.JARVIS_TEST_ROOT;
    const env = { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" };
    const Tasks = require(path.join(backend, "Tasks.js"));
    const Router = require(path.join(backend, "ToolRouter.js"));
    const directories = { state: path.join(root, "state/vgs/jarvis"), runtime: path.join(root, "run/vgs/jarvis") };
    const engine = Tasks.publish(path.join(root, "data/vgs/jarvis"), backend);
    const marks = path.join(root, "marks");
    fs.mkdirSync(marks);
    const cwd = path.join(root, "home");
    const groups = new Set();
    const runners = [];
    const launchers = [];
    let cases = 0, controls = 0, marker = 0;

    // Real processes cross exec, a pipe and the producer's lock. Bound each wait.
    async function until(label, predicate, ms = 10000) {
        const deadline = Date.now() + ms;
        for (;;) {
            const value = await predicate();
            if (value) return value;
            if (Date.now() > deadline) assert.fail("timeout: " + label);
            await sleep(20);
        }
    }
    const readTask = (id, state = directories.state) => new Tasks.Store(state).read(id);
    const taskIds = (state = directories.state) => fs.existsSync(path.join(state, "tasks"))
        ? fs.readdirSync(path.join(state, "tasks")).filter(name => !name.startsWith(".")).sort() : [];
    // The launcher as a terminal runs it: in a session of its own.
    async function launch(file, spec) {
        const child = cp.spawn("python3", [file, "--spec", spec], { env, stdio: ["ignore", "pipe", "pipe"], detached: true });
        let stderr = "";
        child.stderr.on("data", chunk => { stderr += chunk; });
        const timer = setTimeout(() => child.kill("SIGKILL"), 20000);
        const [status, signal] = await once(child, "close");
        clearTimeout(timer);
        return { status, signal, stderr };
    }
    const groupState = pgid => { try { process.kill(-pgid, 0); return "present"; } catch (error) { return error.code; } };
    function producer(kind, id, data, state = directories.state) {
        const result = cp.spawnSync("node", [engine, "--state", state, id, kind],
            { env, input: JSON.stringify(data), encoding: "utf8", timeout: 10000 });
        assert.equal(result.status, 0, result.stderr);
    }

    // One world per scenario: a runner over the given modules, its ports and
    // what it did. mode/marker reach the fixture agent through its argv.
    function world(modules, options = {}) {
        const { Runner, Profiles } = modules;
        const seen = { kills: [], counts: [], failures: [], writes: [], atStopped: [], display: [], launchers: [] };
        const launch = { mode: "children", marker: null };
        const row = account => ({ program: "fixture-agent", account, interrupt: { signal: "SIGINT" }, interruptMs: 300,
            argv: task => ["fixture-agent", launch.mode, launch.marker, task.brief] });
        const profiles = Profiles.table({ fixture: row({ variable: "FIXTURE_ACCOUNT" }), plain: row(null) });
        let runner = null;
        const display = { run(args) {
            seen.display.push(args);
            if (options.answer !== undefined) return Promise.resolve(options.answer);
            if (options.display !== undefined) return options.display(runner, args);
            // A terminal runs its command in a session of its own.
            const child = cp.spawn("python3", [path.join(backend, "task-run.py"), "--spec", args[0]],
                { env, stdio: ["ignore", "pipe", "pipe"], detached: true });
            // closed waits for the pipes too, which a surviving agent holds open.
            const entry = { child, stderr: "", closed: once(child, "close"), exited: once(child, "exit") };
            child.stderr.on("data", chunk => { entry.stderr += chunk; });
            child.on("close", () => runner.tuiState(false));
            seen.launchers.push(entry);
            launchers.push(child);
            runner.tuiState(true);
            return Promise.resolve("ok");
        } };
        runner = Runner.create({ directories: { ...directories, ...options.directories },
            engine: options.engine ?? engine, backend, profiles,
            settings: () => ({ taskTerminal: options.terminal ?? "floating" }), display,
            count: value => seen.counts.push(value), failed: error => seen.failures.push(error.message),
            accounts: (agent, reference) => reference,
            environment: { ...env, XDG_RUNTIME_DIR: path.join(root, "run"), VGSH_RUNNER_PID: "1", FIXTURE_SECRET: "x" },
            lookup: command => command === "fixture-agent" || (command === "tmux" && options.tmuxPresent !== false),
            tmux: options.tmux ?? path.join(root, "bootstrap/tmux"),
            clock: { now: () => Date.now() + (options.offset ?? 0), set: setTimeout, clear: clearTimeout },
            processes: { ...Runner.PROCESSES, kill(target, signal) {
                seen.kills.push([target, signal]);
                if (options.onKill) options.onKill(target, signal);
                return Runner.PROCESSES.kill(target, signal);
            } },
            spawn: (file, args, spawnOptions) => {
                seen.writes.push(args.slice(3));
                if (options.beforeWrite) options.beforeWrite(args.slice(3));
                if (args[4] === "stopped") seen.atStopped.push(groupState(readTask(args[3], args[2]).identity.pgid));
                return spawnFixture(file, args, spawnOptions);
            } });
        runners.push(runner);
        if (options.tui !== "unknown") runner.tuiState(false);
        function start(args, mode = "children", release = () => "send") {
            launch.mode = mode;
            launch.marker = path.join(marks, String(++marker));
            const executor = runner.executor(async (...values) => release(...values));
            return new Promise(resolve => executor.start(Object.freeze({ id: "task.start",
                args: { goal: "Fixture goal", cwd, ...args } }), resolve)).then(answer => ({ ...answer,
                result: JSON.parse(answer.content), marker: launch.marker }));
        }
        async function started(answer) {
            assert.equal(answer.outcome, "completed", answer.content);
            const task = await until("started " + answer.result.task, () => {
                const record = readTask(answer.result.task);
                return record.process.kind === "alive" && record;
            }).catch(error => {
                throw new assert.AssertionError({ message: error.message + " launchers="
                    + JSON.stringify(seen.launchers.map(entry => entry.stderr)) });
            });
            groups.add(task.identity.pgid);
            const agent = await until("agent marker", () => fs.existsSync(answer.marker)
                && JSON.parse(fs.readFileSync(answer.marker, "utf8")));
            return { task, agent };
        }
        return { runner, seen, start, started, profiles };
    }
    const current = { Runner: require(path.join(backend, "TaskRunner.js")), Profiles: require(path.join(backend, "AgentProfiles.js")) };

    // A write larger than the pipe forces EPIPE when this child exits without reading.
    {
        const source = fs.readFileSync(__filename, "utf8");
        const start = "function " + "spawnFixture(";
        const end = "\nasync function inside()";
        assert.equal(source.split(start).length - 1, 1);
        assert.equal(source.split(end).length - 1, 1);
        const fixture = source.slice(source.indexOf(start), source.indexOf(end));
        const script = path.join(root, "spawn-fixture.cjs");
        const harness = `
const assert = require("node:assert/strict");
const cp = require("node:child_process");
${fixture}
const injected = process.argv[2] === "EIO";
if (injected) {
    const spawn = cp.spawn;
    cp.spawn = (...args) => {
        const child = spawn(...args);
        process.nextTick(() => child.stdin.destroy(Object.assign(new Error("fixture stdin"), { code: "EIO" })));
        return child;
    };
}
const answer = spawnFixture("python3", ["-I", "-c", "import os; os._exit(23)"],
    { env: { PATH: process.env.PATH, HOME: process.env.HOME, LANG: "C.UTF-8" }, input: Buffer.alloc(1024 * 1024) });
(async () => {
    if (injected) await assert.rejects(answer, { code: "EIO" });
    else assert.deepEqual(await answer, { code: 23, signal: null, stdout: "", stderr: "" });
})().catch(error => { console.error(error); process.exitCode = 1; });
`;
        const run = (text, kind) => {
            fs.writeFileSync(script, text);
            const result = cp.spawnSync(process.execPath, [script, kind], { env, encoding: "utf8", timeout: 10000 });
            assert.equal(result.error, undefined, result.stderr);
            assert.equal(result.signal, null, result.stderr);
            return result;
        };
        for (const kind of ["EPIPE", "EIO"]) {
            const good = run(harness, kind);
            assert.equal(good.status, 0, good.stderr);
            assert.equal(good.stdout, "");
            assert.equal(good.stderr, "");
            cases++;
        }
        const handler = 'child.stdin.on("error", error => { if (error.code !== "EPIPE") reject(error); });';
        const guard = 'if (error.code !== "EPIPE")';
        for (const [name, kind, needle, replacement, expected] of [
            ["stdin-early-exit", "EPIPE", handler, "", /code: 'EPIPE'/],
            ["stdin-other-error", "EIO", guard, 'if (false && error.code !== "EPIPE")', /ERR_ASSERTION/]
        ]) {
            assert.equal(harness.split(needle).length - 1, 1, name + " match");
            const mutant = harness.replace(needle, replacement);
            assert.notEqual(mutant, harness);
            const bad = run(mutant, kind);
            assert.equal(bad.status, 1, bad.stderr);
            assert.match(bad.stderr, expected);
            console.log("test-jarvis-task-runner: control=" + name + " killed");
            controls++;
        }
        fs.rmSync(script);
    }

    // Each control loads a private backend copy with one planted defect.
    async function control(name, file, needle, replacement, check) {
        const source = fs.readFileSync(path.join(backend, file), "utf8");
        assert.equal(source.split(needle).length - 1, 1, name + " match");
        const changed = source.replace(needle, replacement);
        assert.notEqual(changed, source);
        const copy = path.join(root, "control-" + name);
        fs.mkdirSync(copy);
        for (const entry of ["Tasks.js", "task-event", "TaskRelay.js", "claude-hook", "TaskRunner.js", "AgentProfiles.js", "task-run.py"])
            fs.copyFileSync(path.join(backend, entry), path.join(copy, entry));
        fs.writeFileSync(path.join(copy, file), changed);
        await assert.rejects(async () => check({ Runner: require(path.join(copy, "TaskRunner.js")),
            Profiles: require(path.join(copy, "AgentProfiles.js")), copy }), error => {
            assert.ok(error instanceof assert.AssertionError, name + " must turn red, not crash: " + error.stack);
            console.log("test-jarvis-task-runner: control=" + name + " killed by=" + JSON.stringify(error.message.split("\n")[0]));
            return true;
        });
        for (const runner of runners) runner.close();
        for (const child of launchers) if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
        // A launcher ended here may not have consumed its spec yet.
        fs.rmSync(path.join(directories.runtime, "tasks"), { recursive: true, force: true });
        // A mutant can leave a launched task this suite never read: end every
        // recorded live group by its recorded pgid.
        for (const task of new Tasks.Store(directories.state).list())
            if (task.process.kind === "alive") groups.add(task.identity.pgid);
        for (const pgid of groups) try { process.kill(-pgid, "SIGKILL"); } catch (error) { if (error.code !== "ESRCH") throw error; }
        controls++;
    }

    // Acceptance 2: one floating task at a time, refused before any record.
    async function oneFloating(modules) {
        const w = world(modules);
        const first = await w.started(await w.start({ agent: "fixture" }));
        const before = taskIds();
        const second = await w.start({ agent: "fixture" });
        assert.equal(second.outcome, "failed", "a second floating start is refused");
        assert.equal(second.result.reason, "task-floating-display-busy");
        assert.deepEqual(taskIds(), before, "a refused floating start creates no record");
        assert.equal(w.seen.display.length, 1);
        assert.equal(await w.runner.stop(first.task.id), "stopped");
        await w.seen.launchers[0].closed;
        const third = await w.started(await w.start({ agent: "fixture" }));
        assert.equal(await w.runner.stop(third.task.id), "stopped");
        await w.seen.launchers[1].closed;
        assert.deepEqual(w.seen.failures, []);
        w.runner.close();
        cases++;
    }
    await oneFloating(current);
    await control("floating-one-at-a-time", "TaskRunner.js",
        'if (kind === "floating" && tui !== "idle") return { reason: "floating-display-busy" };', "", oneFloating);

    // Reports apply in message order: a run that ended before the reply's
    // continuation ran leaves the display idle, not busy.
    async function replyOrder(modules) {
        const w = world(modules, { display: (runner, args) => {
            runner.tuiState(true);
            runner.tuiState(false);
            return Promise.resolve("ok");
        } });
        try {
            const first = await w.start({ agent: "fixture" });
            assert.equal(first.outcome, "completed", first.content);
            const second = await w.start({ agent: "fixture" });
            assert.equal(second.outcome, "completed", "a reply cannot overwrite a later idle report: " + second.content);
        } finally {
            // This display runs no launcher, so no spec was consumed.
            for (const [spec] of w.seen.display) fs.rmSync(spec, { force: true });
        }
        w.runner.close();
        cases++;
    }
    await replyOrder(current);
    await control("reply-order", "TaskRunner.js", "if (reports === before) tui = \"busy\";", "tui = \"busy\";", replyOrder);

    // Acceptance 1: stopped is written only after the group reads empty. The
    // launcher is held stopped, so the killed leader stays an unreaped zombie
    // in its group until the launcher resumes.
    async function stopAfterEmpty(modules, resume = true) {
        let launcher = null, killed = false, resumed = false;
        // Resume on the first empty read after SIGKILL, not after a delay.
        const w = world(modules, { onKill: (target, signal) => {
            if (signal === "SIGKILL") killed = true;
            else if (signal === 0 && killed && resume && !resumed) { resumed = true; launcher.kill("SIGCONT"); }
        } });
        const { task, agent } = await w.started(await w.start({ agent: "fixture" }, "ignore-term"));
        launcher = w.seen.launchers[0].child;
        assert.equal(agent.children.length, 2);
        for (const pid of agent.children) assert.equal(fs.readFileSync("/proc/" + pid + "/stat", "utf8").split(") ")[1].split(" ")[2], String(task.identity.pgid));
        launcher.kill("SIGSTOP");
        const answer = await w.runner.stop(task.id);
        assert.deepEqual(w.seen.kills.filter(([, signal]) => signal !== 0),
            [[-task.identity.pgid, "SIGINT"], [-task.identity.pgid, "SIGTERM"], [-task.identity.pgid, "SIGKILL"]]);
        if (!resume) {
            assert.equal(answer, "stop-incomplete");
            assert.equal(readTask(task.id).process.kind, "alive", "an incomplete stop writes nothing");
            assert.equal(groupState(task.identity.pgid), "present");
            launcher.kill("SIGCONT");
        } else {
            assert.equal(answer, "stopped");
            assert.deepEqual(w.seen.atStopped, ["ESRCH"], "stopped follows the empty read");
        }
        await w.seen.launchers[0].closed;
        await until("launcher exit record", () => readTask(task.id).events.some(event => event.kind === "exited"));
        const record = readTask(task.id);
        assert.deepEqual(record.events.find(event => event.kind === "exited").data, { code: 137 });
        assert.equal(record.state, resume ? "stopped" : "failed");
        for (const pid of [agent.leader, ...agent.children]) await until("reaped " + pid, () => !fs.existsSync("/proc/" + pid));
        w.runner.close();
        cases++;
    }
    await stopAfterEmpty(current);
    await control("stopped-after-empty", "TaskRunner.js", "const probe = await settle(task.identity.pgid, window);",
        'const probe = signal === "SIGKILL" ? "empty" : await settle(task.identity.pgid, window);', stopAfterEmpty);
    await stopAfterEmpty(current, false);

    // The profile's interrupt, then SIGTERM once interruptMs passes.
    {
        const w = world(current);
        const { task } = await w.started(await w.start({ agent: "fixture" }, "ignore-int"));
        const [answer, again] = await Promise.all([w.runner.stop(task.id), w.runner.stop(task.id)]);
        assert.deepEqual([answer, again], ["stopped", "stop-in-flight"]);
        assert.deepEqual(w.seen.kills.filter(([, signal]) => signal !== 0).map(([, signal]) => signal), ["SIGINT", "SIGTERM"]);
        await w.seen.launchers[0].closed;
        assert.equal(readTask(task.id).state, "stopped");
        assert.equal(await w.runner.stop(task.id), "not-alive");
        assert.equal(await w.runner.stop("absent-task"), "task-unknown");
        w.runner.close();
        cases += 3;
    }

    // Identity is read before every signal: a reused pid or a dead group
    // ends as lost, and nothing is signalled.
    async function identityGate(modules) {
        const bystander = cp.spawn("sleep", ["30"], { detached: true, stdio: "ignore" });
        const exited = once(bystander, "exit");
        try {
            const stat = fs.readFileSync("/proc/" + bystander.pid + "/stat", "utf8").split(") ")[1].split(" ");
            const id = "reused-" + bystander.pid;
            producer("create", id, { goal: "Fixture goal", cwd, agent: "fixture", account: "" });
            producer("started", id, { pid: bystander.pid, pgid: Number(stat[2]), sid: Number(stat[3]), startTime: "1" });
            const w = world(modules);
            assert.equal(await w.runner.stop(id), "identity-mismatch", "a reused leader pid is not this task");
            assert.deepEqual(w.seen.kills, [], "no signal reaches a group whose identity failed");
            assert.equal(readTask(id).process.kind, "lost");
            assert.equal(groupState(bystander.pid), "present");
            w.runner.close();
            cases++;
        } finally { bystander.kill("SIGKILL"); await exited; }
    }
    await identityGate(current);
    await control("identity-before-signal", "TaskRunner.js", "const seen = await identity(task);", 'const seen = "match";', identityGate);
    {
        const gone = cp.spawn("true", [], { detached: true, stdio: "ignore" });
        const stat = fs.readFileSync("/proc/" + gone.pid + "/stat", "utf8").split(") ")[1].split(" ");
        await once(gone, "exit");
        producer("create", "ended-group", { goal: "Fixture goal", cwd, agent: "unknown-agent", account: "" });
        producer("started", "ended-group", { pid: gone.pid, pgid: Number(stat[2]), sid: Number(stat[3]), startTime: stat[19] });
        const w = world(current);
        assert.equal(await w.runner.stop("ended-group"), "already-ended");
        assert.deepEqual(w.seen.kills, []);
        assert.equal(readTask("ended-group").state, "lost", "an empty group before any signal is not a stop");
        w.runner.close();
        cases++;
    }

    // A gone process whose stat fields identify a group that no longer exists.
    async function goneIdentity() {
        const gone = cp.spawn("true", [], { detached: true, stdio: "ignore" });
        const stat = fs.readFileSync("/proc/" + gone.pid + "/stat", "utf8").split(") ")[1].split(" ");
        await once(gone, "exit");
        return { pid: gone.pid, pgid: Number(stat[2]), sid: Number(stat[3]), startTime: stat[19] };
    }

    // lost is compare-and-set: when the launcher's exit lands between the
    // controller's read and its lost, the producer answers stale and the
    // controller reads the task again instead of failing.
    async function staleLost(modules) {
        const ids = ["race-observe-" + (++marker), "race-stop-" + marker];
        for (const id of ids) {
            producer("create", id, { goal: "Fixture goal", cwd, agent: "fixture", account: "" });
            producer("started", id, await goneIdentity());
        }
        const landed = new Set();
        const w = world(modules, { beforeWrite: ([id, kind]) => {
            if (kind === "lost" && ids.includes(id) && !landed.has(id)) {
                landed.add(id);
                producer("exited", id, { code: 0 });
            }
        } });
        assert.equal(await w.runner.stop(ids[1]), "not-alive", "a stop that met the exit reads the task again");
        await w.runner.observe();
        for (const id of ids) assert.deepEqual(readTask(id).process, { kind: "exited", code: 0 }, id);
        assert.deepEqual(w.seen.failures, []);
        w.runner.close();
        cases += 2;
    }
    await staleLost(current);
    await control("stale-lost", "TaskRunner.js", 'if (answer !== null && answer.reason === "stale" && kind === "lost") return "stale";',
        "void 0;", staleLost);

    // The member rule: with the leader gone, the group's members in the
    // recorded session that started after it are the task's, and a stop ends them.
    async function members(modules) {
        const w = world(modules);
        const { task, agent } = await w.started(await w.start({ agent: "fixture" }));
        const launcher = w.seen.launchers[0];
        launcher.child.kill("SIGKILL");
        await launcher.exited;
        process.kill(agent.leader, "SIGKILL");
        await until("leader reaped", () => !fs.existsSync("/proc/" + agent.leader));
        assert.equal(readTask(task.id).process.kind, "alive");
        assert.equal(await w.runner.stop(task.id), "stopped", "members of a gone leader are the task's");
        assert.deepEqual(w.seen.kills.filter(([, signal]) => signal !== 0), [[-task.identity.pgid, "SIGINT"]]);
        for (const pid of agent.children) await until("member ended " + pid, () => !fs.existsSync("/proc/" + pid));
        w.runner.close();
        cases++;
    }
    await members(current);
    await control("member-rule", "TaskRunner.js", '>= BigInt(startTime))\n            ? "match" : "mismatch";',
        '>= BigInt(startTime))\n            ? "mismatch" : "mismatch";', members);
    async function memberSession(modules) {
        const bystander = cp.spawn("sleep", ["30"], { detached: true, stdio: "ignore" });
        const exited = once(bystander, "exit");
        try {
            const stat = fs.readFileSync("/proc/" + bystander.pid + "/stat", "utf8").split(") ")[1].split(" ");
            const id = "other-session-" + (++marker);
            producer("create", id, { goal: "Fixture goal", cwd, agent: "fixture", account: "" });
            producer("started", id, { ...await goneIdentity(), pgid: bystander.pid, sid: Number(stat[3]) + 1, startTime: "1" });
            const w = world(modules);
            assert.equal(await w.runner.stop(id), "identity-mismatch", "a member of another session is not the task's");
            assert.deepEqual(w.seen.kills, []);
            assert.equal(groupState(bystander.pid), "present");
            assert.equal(readTask(id).process.kind, "lost");
            w.runner.close();
            cases++;
        } finally { bystander.kill("SIGKILL"); await exited; }
    }
    await memberSession(current);
    await control("member-session", "TaskRunner.js", "members.every(member => member.sid === sid && ",
        "members.every(member => ", memberSession);

    // A leader's exit leaves its background children in the group: a stop
    // still admits the exited task and ends them.
    async function orphans(modules) {
        const w = world(modules);
        const answer = await w.start({ agent: "fixture" }, "orphan");
        const [status] = await w.seen.launchers[0].exited;
        assert.equal(status, 0);
        const task = readTask(answer.result.task);
        const agent = JSON.parse(fs.readFileSync(answer.marker, "utf8"));
        groups.add(task.identity.pgid);
        assert.deepEqual(task.process, { kind: "exited", code: 0 });
        assert.equal(groupState(task.identity.pgid), "present");
        assert.equal(await w.runner.stop(task.id), "stopped", "an exited task's surviving members stop");
        assert.equal(readTask(task.id).state, "stopped");
        for (const pid of agent.children) await until("orphan ended " + pid, () => !fs.existsSync("/proc/" + pid));
        assert.equal(await w.runner.stop(task.id), "not-alive");
        w.runner.close();
        cases++;
    }
    await orphans(current);
    await control("exited-members", "TaskRunner.js",
        'if (!alive && (task.process.kind !== "exited" || task.identity === null)) return "not-alive";',
        'if (!alive) return "not-alive";', orphans);

    // Past the event ceiling a stop and the launcher's exit go to the noisy
    // marker; both count as recorded, and neither fails the daemon.
    async function capped(modules) {
        const w = world(modules);
        const { task } = await w.started(await w.start({ agent: "fixture" }));
        seedTaskEvents(path.join(directories.state, "tasks", task.id, "events"), 2000, 2);
        assert.equal(await w.runner.stop(task.id), "stopped", "a stop past the event ceiling is recorded");
        const [status] = await w.seen.launchers[0].closed;
        assert.equal(status, 0);
        const record = readTask(task.id);
        assert.deepEqual([record.process.kind, record.noisy, record.terminal.kind], ["stopped", true, "stopped"]);
        assert.deepEqual(w.seen.failures, []);
        w.runner.close();
        cases++;
    }
    await capped(current);
    await control("capped-stop", "TaskRunner.js", 'answer.reason === "event-count" && Tasks.terminalKind(kind)', "false", capped);

    // Observation: lost where due, a stale spec removed, the live count published.
    async function observation(modules) {
        const bystander = cp.spawn("sleep", ["30"], { detached: true, stdio: "ignore" });
        const exited = once(bystander, "exit");
        const state = path.join(root, "state/observe-" + (++marker));
        try {
            const stat = fs.readFileSync("/proc/" + bystander.pid + "/stat", "utf8").split(") ")[1].split(" ");
            for (const id of ["mismatch", "stale"])
                producer("create", id, { goal: "Fixture goal", cwd, agent: "fixture", account: "" }, state);
            producer("started", "mismatch", { pid: bystander.pid, pgid: Number(stat[2]), sid: Number(stat[3]), startTime: "1" }, state);
            const spec = path.join(root, "run/observe/tasks/stale.json");
            fs.mkdirSync(path.dirname(spec), { recursive: true });
            fs.writeFileSync(spec, "{}", { mode: 0o600 });
            const old = new Tasks.Store(state).read("stale").createdAt;
            const w = world(modules, { directories: { state, runtime: path.join(root, "run/observe") },
                offset: 31000 - (Date.now() - old) });
            await w.runner.observe();
            assert.equal(readTask("mismatch", state).state, "lost", "observation writes lost on an identity mismatch");
            assert.equal(readTask("stale", state).state, "lost");
            assert.equal(fs.existsSync(spec), false, "a stale spec is removed");
            assert.equal(groupState(bystander.pid), "present");
            assert.deepEqual(w.seen.kills, []);
            w.runner.close();
            cases++;
        } finally { bystander.kill("SIGKILL"); await exited; }
    }
    await observation(current);
    await control("observe-identity", "TaskRunner.js", 'if (stopping.has(task.id) || await identity(task) === "match") live++;',
        "if (true) live++;", observation);
    {
        const state = path.join(root, "state/count");
        producer("create", "young", { goal: "Fixture goal", cwd, agent: "fixture", account: "" }, state);
        const w = world(current, { directories: { state } });
        await w.runner.observe();
        assert.deepEqual(w.seen.counts, [1], "a starting task inside the launch window is live");
        assert.equal(readTask("young", state).state, "starting");
        // A task TUI's end is observed at once.
        producer("lost", "young", { seq: 0 }, state);
        w.runner.tuiState(true);
        w.runner.tuiState(false);
        await until("count after the TUI ended", () => w.seen.counts.length === 2);
        assert.deepEqual(w.seen.counts, [1, 0]);
        w.runner.close();
        cases += 2;
    }

    // tmux: a private -S socket in the runtime directory, any number of tasks.
    {
        const w = world(current, { terminal: "tmux" });
        const tmux = args => cp.spawnSync(path.join(root, "bootstrap/tmux"),
            ["-S", path.join(directories.runtime, "tmux.sock"), ...args], { env, encoding: "utf8", timeout: 10000 });
        const one = await w.started(await w.start({ agent: "fixture", account: path.join(root, "account") }));
        const two = await w.started(await w.start({ agent: "plain" }));
        for (const { task, agent } of [one, two]) {
            assert.equal(tmux(["has-session", "-t", "jarvis-" + task.id]).status, 0);
            const [pgid, sid] = fs.readFileSync("/proc/" + agent.leader + "/stat", "utf8").split(") ")[1].split(" ").slice(2, 4);
            assert.deepEqual([task.identity.pid, task.identity.pgid, task.identity.sid], [agent.leader, Number(pgid), Number(sid)]);
            assert.equal(agent.cwd, cwd);
            assert.ok(Object.hasOwn(agent.env, "TERM"), "the pane's TERM reaches the agent");
            assert.equal(Object.hasOwn(agent.env, "VGSH_RUNNER_PID") || Object.hasOwn(agent.env, "FIXTURE_SECRET"), false);
        }
        assert.equal(one.agent.env.FIXTURE_ACCOUNT, path.join(root, "account"));
        assert.equal(Object.hasOwn(two.agent.env, "FIXTURE_ACCOUNT"), false);
        assert.equal(fs.statSync(path.join(directories.runtime, "tmux.sock")).isSocket(), true);
        assert.equal(fs.statSync(directories.runtime).mode & 0o777, 0o700);
        assert.deepEqual(w.seen.display, [], "tmux tasks never open the floating TUI");
        for (const { task } of [one, two]) assert.equal(await w.runner.stop(task.id), "stopped");
        for (const { task } of [one, two])
            await until("tmux session ends", () => tmux(["has-session", "-t", "jarvis-" + task.id]).status !== 0);
        tmux(["kill-server"]);
        w.runner.close();
        cases++;
    }

    // Launch refusals: before a record where the start is refused, and a lost
    // record with no spec left behind where the launch itself failed.
    async function refused(options, args, reason, release, record) {
        const w = world(current, options);
        const before = taskIds();
        const answer = await w.start(args, "children", release);
        assert.equal(answer.outcome, "failed");
        assert.equal(answer.result.reason, reason);
        const added = taskIds().filter(id => !before.includes(id));
        assert.equal(added.length, record ? 1 : 0, reason);
        if (record) assert.equal(readTask(added[0]).state, "lost");
        assert.deepEqual(fs.existsSync(path.join(directories.runtime, "tasks"))
            ? fs.readdirSync(path.join(directories.runtime, "tasks")) : [], [], "no spec is left behind: " + reason + " "
            + (fs.existsSync(path.join(directories.runtime, "tasks")) ? fs.readdirSync(path.join(directories.runtime, "tasks"))
                .map(name => fs.readFileSync(path.join(directories.runtime, "tasks", name), "utf8").slice(0, 400)).join(" | ") : ""));
        w.runner.close();
        cases++;
    }
    await refused({ terminal: "tmux", tmuxPresent: false }, { agent: "fixture" }, "task-tmux-missing", undefined, false);
    await refused({}, { agent: "absent" }, "task-agent-unavailable", undefined, false);
    await refused({}, { agent: "plain", account: "/account" }, "task-account-unsupported", undefined, false);
    await refused({}, { agent: "fixture" }, "task-release-refused", () => "withhold", false);
    await refused({ tui: "unknown" }, { agent: "fixture" }, "task-floating-display-busy", undefined, false);
    await refused({ answer: "refused: tui=task reason=busy" }, { agent: "fixture" }, "task-floating-display-busy", undefined, true);
    await refused({ answer: "refused: tui=task reason=launcher-missing" }, {}, "task-floating-launch-refused", undefined, true);
    await refused({ terminal: "tmux", tmux: path.join(root, "tools/false") }, { agent: "fixture" }, "task-tmux-failed", undefined, true);
    {
        const w = world(current, { terminal: "auto", tmuxPresent: false });
        const { task } = await w.started(await w.start({}));
        assert.equal(task.agent, "fixture", "the first available profile is chosen");
        assert.equal(w.seen.display.length, 1, "auto without tmux opens the floating TUI");
        assert.equal(await w.runner.stop(task.id), "stopped");
        await w.seen.launchers[0].closed;
        const router = Router.create({ session: {}, state: () => ({}), dispatch() {}, context: () => ({}), audit: {}, result() {} });
        assert.doesNotThrow(() => router.register("task", w.runner.executor(() => "send")));
        assert.throws(() => w.runner.executor(null), { message: "jarvis: task=release-port" });
        w.runner.close();
        cases++;
    }

    // The brief's own report command records the outcome, through paths that
    // need quoting, with no hand-written producer call.
    async function brief(modules) {
        const state = path.join(root, "state/it's a \"state\" $(dir)");
        const quotedEngine = Tasks.publish(path.join(root, "data/o'neil data"), backend);
        const w = world(modules, { directories: { state }, engine: quotedEngine });
        const answer = await w.start({ agent: "fixture" }, "report-ok");
        assert.equal(answer.outcome, "completed", answer.content);
        await w.seen.launchers[0].closed;
        const record = readTask(answer.result.task, state);
        assert.deepEqual([record.outcome.kind, record.state, record.engine], ["reported-ok", "reported-ok", quotedEngine]);
        w.runner.close();
        cases++;
    }
    await brief(current);
    await control("brief-quote", "AgentProfiles.js", "text.replace(/'/g, \"'\\\\''\")", "text", brief);
    const profileRows = [
        ["id", "Bad", {}],
        ["program", "ok", { program: "/usr/bin/agent" }],
        ["account", "ok", { account: { variable: "PATH" } }],
        ["signal", "ok", { interrupt: { signal: "SIGKILL" } }],
        ["interrupt", "ok", { interruptMs: 50 }],
        ["shape", "ok", { extra: true }]
    ];
    const good = { program: "agent", argv: () => ["agent"], account: null, interrupt: { signal: "SIGINT" }, interruptMs: 300 };
    for (const [name, id, change] of profileRows)
        assert.throws(() => current.Profiles.table({ [id]: { ...good, ...change } }), /jarvis: profiles=(row|id)/, name);
    const table = current.Profiles.table({ agent: { ...good, argv: () => ["other"] } });
    assert.throws(() => current.Profiles.command(table.agent, {}), { message: "jarvis: profiles=argv program=agent" });
    assert.deepEqual(Object.keys(current.Profiles.TABLE), ["claude"], "production ships the Claude Code profile");
    cases += profileRows.length + 1;

    // task-run.py directly: the spec is one-shot and judged; started is
    // recorded before exec; exit codes follow a signal death.
    async function taskRun(file, id, spec, mode = "children") {
        const mark = path.join(marks, String(++marker));
        const path0 = path.join(root, "specs", id + ".json");
        fs.mkdirSync(path.dirname(path0), { recursive: true });
        const value = spec ?? { v: 1, id, state: directories.state, engine, cwd,
            argv: ["fixture-agent", mode, mark, "brief"], env };
        fs.writeFileSync(path0, typeof value === "string" ? value : JSON.stringify(value), { mode: 0o600 });
        return { ...await launch(file, path0), spec: path0, mark };
    }
    async function launcher(modules) {
        const file = path.join(modules.copy ?? backend, "task-run.py");
        // A death by signal is recorded as 128+N; the launcher exits 0 so the
        // floating window closes without a failure prompt.
        const exits = [["exit-3", 3, 3], ["self-term", 143, 0]];
        for (const [mode, code, status] of exits) {
            const id = "run-" + mode + "-" + (++marker);
            producer("create", id, { goal: "Fixture goal", cwd, agent: "fixture", account: "" });
            const result = await taskRun(file, id, undefined, mode);
            assert.equal(result.status, status, "launcher status after " + mode + ": " + result.stderr);
            assert.deepEqual(readTask(id).events.map(event => event.kind), ["started", "exited"]);
            assert.deepEqual(readTask(id).events[1].data, { code }, "recorded code after " + mode);
            assert.equal(fs.existsSync(result.spec), false, "the spec is consumed");
            const again = await launch(file, result.spec);
            assert.equal(again.status, 65);
            assert.equal(again.stderr.trim(), "jarvis: task-run=spec-open cause=ENOENT");
        }
        const held = "run-held-" + (++marker);
        producer("create", held, { goal: "Fixture goal", cwd, agent: "fixture", account: "" });
        const broken = await taskRun(file, held, { v: 1, id: held, state: directories.state,
            engine: path.join(root, "absent-engine"), cwd, argv: ["fixture-agent", "exit-0", path.join(marks, held), "b"], env });
        assert.equal(broken.status, 74, broken.stderr);
        assert.match(broken.stderr, /^jarvis: task-run=record kind=started status=1 /);
        assert.equal(fs.existsSync(path.join(marks, held)), false, "a held child never execs without started");
        assert.deepEqual(readTask(held).events, []);
        // Past the event ceiling the exit goes to the noisy marker and counts.
        const full = "run-capped-" + (++marker);
        producer("create", full, { goal: "Fixture goal", cwd, agent: "fixture", account: "" });
        seedTaskEvents(path.join(directories.state, "tasks", full, "events"), 1999);
        const ceiling = await taskRun(file, full, undefined, "exit-3");
        assert.equal(ceiling.status, 3, ceiling.stderr);
        assert.deepEqual([readTask(full).process, readTask(full).noisy], [{ kind: "exited", code: 3 }, true]);
        cases += exits.length + 2;
    }
    await launcher(current);
    await control("launcher-one-shot", "task-run.py", "    os.unlink(path)\n", "    pass\n", launcher);
    await control("launcher-signal-code", "task-run.py", "        code = 128 - code\n", "        code = -code\n", launcher);
    await control("launcher-signal-status", "task-run.py", "    return 0 if code >= 128 else code\n", "    return code\n", launcher);
    await control("launcher-capped-exit", "task-run.py", 'if result.returncode == 75 and kind == "exited":',
        "if False:", launcher);
    await control("launcher-held", "task-run.py", "        os.kill(pid, signal.SIGKILL)\n",
        "        os.write(release_write, b\"x\")\n", launcher);
    producer("create", "run-exec", { goal: "Fixture goal", cwd, agent: "fixture", account: "" });
    const missing = await taskRun(path.join(backend, "task-run.py"), "run-exec", { v: 1, id: "run-exec",
        state: directories.state, engine, cwd, argv: ["absent-agent"], env });
    assert.equal(missing.status, 127);
    assert.equal(missing.stderr.trim(), "jarvis: task-run=exec cause=ENOENT id=run-exec");
    assert.deepEqual(readTask("run-exec").events[1].data, { code: 127 });
    const specRows = [
        ["shape", JSON.stringify({ v: 1, id: "x", state: "/s", engine: "/e", cwd: "/c", argv: ["a"], env, extra: 1 }), 0o600, "spec-shape"],
        ["json", "{", 0o600, "spec-json"],
        ["relative", JSON.stringify({ v: 1, id: "x", state: "s", engine: "/e", cwd: "/c", argv: ["a"], env }), 0o600, "spec-shape"],
        ["mode", "{}", 0o644, "spec-file"],
        ["bytes", "x".repeat(65537), 0o600, "spec-bytes"]
    ];
    for (const [name, text, mode, reason] of specRows) {
        const file = path.join(root, "specs", "bad-" + name + ".json");
        fs.writeFileSync(file, text, { mode });
        fs.chmodSync(file, mode);
        const result = await launch(path.join(backend, "task-run.py"), file);
        assert.equal(result.status, 65, name);
        assert.equal(result.stderr.trim(), "jarvis: task-run=" + reason, name);
        assert.equal(fs.existsSync(file), reason === "spec-file", name + ": a judged spec is removed");
        cases++;
    }
    for (const runner of runners) runner.close();
    console.log("test-jarvis-task-runner: ok cases=" + cases + " controls=" + controls);
}

function main() {
    // A failed case can leave fixture groups and runners alive; end at once.
    if (process.argv[2] === "--inside") return inside().catch(error => { console.error(error); process.exit(1); });
    const parent = path.join(tree, "tmp");
    fs.mkdirSync(parent, { recursive: true });
    const root = fs.realpathSync(fs.mkdtempSync(path.join(parent, "jr-")));
    try {
        const standins = path.join(root, "standins");
        fs.mkdirSync(standins);
        fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis/task-agent.py"), path.join(standins, "fixture-agent"));
        fs.chmodSync(path.join(standins, "fixture-agent"), 0o755);
        const result = cp.spawnSync("/bin/bash", [path.join(tree, "scripts/lib/jarvis-env.sh"), standins,
            "--", "node", __filename, "--inside"], {
            env: { PATH: "/usr/bin:/bin", HOME: root, JARVIS_TEST_SCRATCH_ROOT: path.join(tree, "tmp") },
            encoding: "utf8", timeout: 300000
        });
        process.stdout.write(result.stdout || "");
        process.stderr.write(result.stderr || "");
        if (result.error) throw result.error;
        assert.equal(result.signal, null);
        process.exitCode = result.status;
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
try { main(); } catch (error) { console.error(error); process.exitCode = 1; }
