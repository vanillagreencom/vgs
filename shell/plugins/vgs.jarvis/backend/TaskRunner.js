// Coding-task launch and control. The `task` executor starts an agent through
// task-run.py in a private tmux server or the plugin's floating TUI. The
// controller checks a task's process-group identity, observes liveness and
// stops a group. Every record goes through the task's recorded producer
// (D072); this module never calls a Tasks.Store writer. Display is not
// control: tmux or the TUI only show the terminal task-run.py runs in.
"use strict";
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");
const crypto = require("node:crypto");
const cp = require("node:child_process");
const Tasks = require("./Tasks.js");
const Profiles = require("./AgentProfiles.js");

const LAUNCH_MS = 20000;
// A task with no started record after this is lost; its spec is stale.
const LAUNCH_WINDOW_MS = 30000;
const OBSERVE_MS = 5000;
const ESCALATE_MS = 3000;
const POLL_MS = 50;
const OUTPUT_BYTES = 8192;

function fail(reason) {
    throw new Error("jarvis: task=" + reason);
}

function onPath(command, search) {
    for (const directory of (search || "").split(":")) {
        if (!path.isAbsolute(directory)) continue;
        try { fs.accessSync(path.join(directory, command), fs.constants.X_OK); return true; }
        catch (error) { if (!["ENOENT", "EACCES", "ENOTDIR"].includes(error.code)) throw error; }
    }
    return false;
}

function spawnProcess(file, args, { env, input }) {
    return new Promise((resolve, reject) => {
        const child = cp.spawn(file, args, { env, stdio: ["pipe", "pipe", "pipe"] });
        const output = { stdout: "", stderr: "" };
        for (const name of ["stdout", "stderr"]) {
            child[name].setEncoding("utf8");
            child[name].on("data", text => {
                if (output[name].length < OUTPUT_BYTES) output[name] += text.slice(0, OUTPUT_BYTES - output[name].length);
            });
        }
        // A child that exits before reading answers through its status.
        child.stdin.on("error", error => { if (error.code !== "EPIPE") reject(error); });
        child.on("error", reject);
        child.on("close", (code, signal) => resolve({ code, signal, ...output }));
        child.stdin.end(input);
    });
}

function parseStat(text) {
    const fields = text.slice(text.lastIndexOf(")") + 2).split(" ");
    return { pgid: Number(fields[2]), sid: Number(fields[3]), startTime: fields[19] };
}

async function statOf(pid) {
    try { return parseStat(await fsp.readFile("/proc/" + pid + "/stat", "utf8")); }
    catch (error) {
        if (error.code === "ENOENT" || error.code === "ESRCH") return null;
        throw new Error("jarvis: task=proc-read cause=" + (error.code || error.message));
    }
}

// The default process port: /proc reads and kill(2). Callers may wrap it.
const PROCESSES = {
    stat: statOf,
    async members(pgid) {
        const found = [];
        for (const name of await fsp.readdir("/proc")) {
            if (!/^[0-9]+$/.test(name)) continue;
            const value = await statOf(Number(name));
            if (value !== null && value.pgid === pgid) found.push({ pid: Number(name), ...value });
        }
        return found;
    },
    // "sent", "empty" (ESRCH) or "denied" (EPERM: the group is not ours).
    kill(target, signal) {
        try { process.kill(target, signal); return "sent"; }
        catch (error) {
            if (error.code === "ESRCH") return "empty";
            if (error.code === "EPERM") return "denied";
            throw error;
        }
    }
};

/**
 * create(options) owns task launch, observation and stop for one daemon.
 * directories {state, runtime}; engine: this daemon's published producer;
 * backend: the directory holding task-run.py; profiles: AgentProfiles.table;
 * settings() -> {taskTerminal}; display.run(args) -> Promise<answer> asks the
 * service to open the `task` TUI; count(n) receives the live-task count;
 * failed(error) receives an observation failure. environment, lookup, tmux,
 * clock {now,set,clear}, processes and spawn are injectable for tests.
 */
function create({ directories, engine, backend, profiles = Profiles.TABLE, settings, display, count, failed,
    environment = process.env, lookup = command => onPath(command, environment.PATH),
    tmux = "tmux", clock, processes = PROCESSES, spawn = spawnProcess }) {
    const { state, runtime } = directories;
    const store = new Tasks.Store(state);
    const specs = path.join(runtime, "tasks");
    const socket = path.join(runtime, "tmux.sock");
    const base = Profiles.base(environment);
    const stopping = new Set();
    // The `task` TUI as the service last reported it; unknown until it does.
    let tui = "unknown";
    let requesting = false;
    let observing = null;
    let again = false;
    let timer = null;
    let published = 0;
    let closed = false;

    const sleep = ms => new Promise(resolve => clock.set(resolve, ms));

    async function write(task, kind, data = {}) {
        const result = await spawn(process.execPath, [task.engine, "--state", state, task.id, kind],
            { env: { PATH: environment.PATH || "/usr/bin:/bin", LANG: "C.UTF-8" }, input: JSON.stringify(data) });
        if (result.signal === null && result.code === 0) return;
        // The noisy marker retains a terminal observation past the event ceiling.
        if (result.signal === null && result.code === 75 && Tasks.terminalKind(kind)) {
            let answer = null;
            try { answer = JSON.parse(result.stdout); } catch { answer = null; }
            if (answer !== null && answer.reason === "event-count") return;
        }
        fail("record kind=" + kind + " id=" + task.id + " status=" + result.code + " signal=" + result.signal
            + " cause=" + (result.stderr.trim().split("\n")[0] || "none"));
    }

    // match: the recorded group is this task's; empty: no member remains;
    // mismatch: the pid or group now belongs to something else.
    async function identity(task) {
        const { pid, pgid, sid, startTime } = task.identity;
        const leader = await processes.stat(pid);
        // A leader pid with other start ticks was reallocated: not this task.
        if (leader !== null)
            return leader.startTime === startTime && leader.pgid === pgid && leader.sid === sid ? "match" : "mismatch";
        // A pid is not reallocated while it names a live group, so members of
        // the recorded group in the recorded session started after the leader
        // are the task's own.
        const members = await processes.members(pgid);
        if (members.length === 0) return "empty";
        return members.every(member => member.sid === sid && BigInt(member.startTime) >= BigInt(startTime))
            ? "match" : "mismatch";
    }

    async function settle(pgid, window) {
        const deadline = clock.now() + window;
        for (;;) {
            const probe = processes.kill(-pgid, 0);
            if (probe !== "sent" || clock.now() >= deadline) return probe;
            await sleep(POLL_MS);
        }
    }

    async function stopTask(id) {
        if (!fs.existsSync(path.join(store.root, id))) return "task-unknown";
        const task = store.read(id);
        if (task.process.kind !== "alive") return "not-alive";
        const row = Object.hasOwn(profiles, task.agent) ? profiles[task.agent] : null;
        const steps = [[row === null ? "SIGINT" : row.interrupt.signal, row === null ? ESCALATE_MS : row.interruptMs],
            ["SIGTERM", ESCALATE_MS], ["SIGKILL", ESCALATE_MS]];
        let signalled = false;
        for (const [signal, window] of steps) {
            const seen = await identity(task);
            if (closed) return "daemon-ending";
            if (seen === "mismatch") { await write(task, "lost"); return "identity-mismatch"; }
            if (seen === "empty") break;
            const sent = processes.kill(-task.identity.pgid, signal);
            if (sent === "denied") { await write(task, "lost"); return "identity-mismatch"; }
            if (sent === "empty") break;
            signalled = true;
            const probe = await settle(task.identity.pgid, window);
            if (probe === "denied") { await write(task, "lost"); return "identity-mismatch"; }
            if (probe === "empty") break;
            if (closed) return "daemon-ending";
            if (signal === "SIGKILL") return "stop-incomplete";
        }
        // The group read empty. Before any signal that is an ended task, not a stop.
        await write(task, signalled ? "stopped" : "lost");
        return signalled ? "stopped" : "already-ended";
    }

    /** Stop one task: answers "stopped" or a keyed refusal; one stop per task. */
    async function stop(id) {
        if (closed) return "daemon-ending";
        if (stopping.has(id)) return "stop-in-flight";
        stopping.add(id);
        try { return await stopTask(id); }
        catch (error) {
            // A record or /proc failure is the store's, as in observation.
            if (!closed) failed(error);
            return "stop-failed";
        }
        finally {
            stopping.delete(id);
            void observe();
        }
    }

    async function removeSpec(id) {
        try { await fsp.unlink(path.join(specs, id + ".json")); }
        catch (error) { if (error.code !== "ENOENT") throw error; }
    }

    async function sweep() {
        let live = 0;
        for (const task of store.list()) {
            if (closed) return;
            if (task.process.kind === "starting") {
                if (clock.now() - task.createdAt < LAUNCH_WINDOW_MS) { live++; continue; }
                await removeSpec(task.id);
                await write(task, "lost");
            } else if (task.process.kind === "alive") {
                if (stopping.has(task.id) || await identity(task) === "match") live++;
                else await write(task, "lost");
            }
        }
        if (closed) return;
        if (live !== published) {
            published = live;
            count(live);
        }
        if (live > 0 && timer === null) timer = clock.set(() => { timer = null; void observe(); }, OBSERVE_MS);
    }

    /** Observe every task record: lost where due, then publish the live count. */
    function observe() {
        if (closed) return Promise.resolve();
        if (observing !== null) { again = true; return observing; }
        observing = (async () => {
            do { again = false; await sweep(); } while (again && !closed);
        })().catch(error => { if (!closed) failed(error); }).finally(() => { observing = null; });
        return observing;
    }

    /** The service's report of the `task` TUI. Its end is observed at once. */
    function tuiState(running) {
        const ended = tui === "busy" && !running;
        tui = running ? "busy" : "idle";
        if (ended) void observe();
    }

    function terminal() {
        const choice = settings().taskTerminal;
        const present = lookup("tmux");
        switch (choice) {
        case "tmux": return present ? "tmux" : null;
        case "floating": return "floating";
        case "auto": return present ? "tmux" : "floating";
        default: fail("terminal value=" + choice);
        }
    }

    async function writeSpec(file, spec) {
        for (const directory of [runtime, specs]) {
            await fsp.mkdir(directory, { recursive: true, mode: 0o700 });
            await fsp.chmod(directory, 0o700);
        }
        const temporary = path.join(specs, "." + crypto.randomUUID() + ".tmp");
        await fsp.writeFile(temporary, JSON.stringify(spec), { flag: "wx", mode: 0o600 });
        try { await fsp.rename(temporary, file); }
        finally { await fsp.rm(temporary, { force: true }); }
    }

    // Show the launcher's terminal: null once it runs, else a keyed refusal.
    async function show(kind, id, cwd, file) {
        if (kind === "floating") {
            const answer = await display.run([file]);
            if (answer === "ok") { tui = "busy"; return null; }
            return / reason=busy$/.test(answer) ? "floating-display-busy" : "floating-launch-refused";
        }
        const result = await spawn(tmux, ["-S", socket, "new-session", "-d", "-s", "jarvis-" + id, "-c", cwd, "--",
            "python3", path.join(backend, "task-run.py"), "--spec", file], { env: base, input: "" });
        return result.signal === null && result.code === 0 ? null : "tmux-failed";
    }

    async function launch(args, release) {
        if (closed) return { reason: "daemon-ending" };
        const offered = Profiles.available(lookup, profiles);
        const agent = args.agent ?? (offered.length > 0 ? offered[0].id : null);
        const entry = offered.find(item => item.id === agent);
        if (entry === undefined) return { reason: "agent-unavailable" };
        const account = args.account ?? "";
        if (account !== "" && entry.row.account === null) return { reason: "account-unsupported" };
        const kind = terminal();
        if (kind === null) return { reason: "tmux-missing" };
        if (kind === "floating" && (requesting || tui !== "idle")) return { reason: "floating-display-busy" };
        if (kind === "floating") requesting = true;
        try {
            if (await release(args.goal, agent, account) !== "send") return { reason: "release-refused" };
            const id = crypto.randomUUID();
            const task = { id, engine };
            await write(task, "create", { goal: args.goal, cwd: args.cwd, agent, account });
            const file = path.join(specs, id + ".json");
            let refusal = "launch-failed";
            try {
                const brief = Profiles.brief({ goal: args.goal, engine, state, id });
                await writeSpec(file, { v: 1, id, state, engine, cwd: args.cwd,
                    argv: Profiles.command(entry.row, { brief, cwd: args.cwd, account }),
                    env: Profiles.environment(entry.row, account, environment) });
                refusal = await show(kind, id, args.cwd, file);
            } finally {
                if (refusal !== null) {
                    await removeSpec(id);
                    await write(task, "lost");
                }
            }
            void observe();
            return refusal === null ? { task: id, terminal: kind } : { reason: refusal };
        } finally { requesting = false; }
    }

    /**
     * The router's `task` executor. release(goal, agent, account) is the
     * release gate's answer for the goal's recipients: "send" or a refusal.
     */
    function executor(release) {
        if (typeof release !== "function") fail("release-port");
        return {
            timeoutMs: LAUNCH_MS, cancellable: false, commands: [],
            start(call, done) {
                launch(call.args, release).then(result => done(result.reason === undefined
                    ? { outcome: "completed", content: JSON.stringify(result) }
                    : { outcome: "failed", content: JSON.stringify({ kind: "refuse", reason: "task-" + result.reason }) }),
                error => done({ outcome: "failed", content: JSON.stringify({ kind: "refuse",
                    reason: "task-failed", cause: error.message.slice(0, 180) }) }));
            }
        };
    }

    /** Teardown stops observation only. Tasks outlive the daemon. */
    function close() {
        closed = true;
        if (timer !== null) clock.clear(timer);
        timer = null;
    }

    return Object.freeze({ executor, stop, observe, tuiState, close });
}

module.exports = { create, PROCESSES };
