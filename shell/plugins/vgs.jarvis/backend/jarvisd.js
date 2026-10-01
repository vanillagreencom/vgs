#!/usr/bin/env node
// jarvisd --tree ABSOLUTE_VGS_TREE
// Stdin is the service's lease. EOF exits 0; a partial line or a refused
// message exits 65. Task-store or confirmation-audit failure exits 74. Node below 22 or a
// mute-store failure exits 78. Stdout carries v1 status/state
// messages and shell requests judged by JarvisProtocol; stderr carries keyed jarvis: failures.
// A reply for a request that awaits none exits 65 like any refused message.
// Startup validates coding-task records and publishes their durable producer,
// then TaskRunner observes them; tasks outlive this process and EOF stops
// only that observation. A task-stop intent answers with task-answer.
// Device discovery is read-only. The chained engine raises the gate only for a
// ready speech adapter and brain; no adapter row ships, so capture stays
// unconfigured. EOF closes the audio owner and waits for all child exits.
"use strict";
const path = require("node:path");
const fs = require("node:fs");
const { StringDecoder } = require("node:string_decoder");
const Tasks = require("./Tasks.js");
const cp = require("node:child_process");

function refuse(code, reason) {
    process.stderr.write(reason + "\n");
    process.exitCode = code;
    process.stdin.destroy();
}

if (Number(process.versions.node.split(".")[0]) < 22) {
    refuse(78, "jarvis: node=" + process.versions.node + " need=22");
} else if (process.argv.length !== 4 || process.argv[2] !== "--tree" || !path.isAbsolute(process.argv[3])) {
    refuse(2, "jarvis: arguments=expected-tree");
} else {
    const Audit = require("./Audit.js");
    const ToolRouter = require("./ToolRouter.js");
    const ShellRequests = require("./ShellRequests.js");
    const Executors = require("./Executors.js");
    const TaskRunner = require("./TaskRunner.js");
    const ToolBridge = require("./ToolBridge.js");
    const ChainedEngine = require("./ChainedEngine.js");
    const { Accounts } = require("./Accounts.js");
    const { load } = require(path.join(process.argv[3], "bin/lib/qml-library.js"));
    const { commandFile, onPath } = require(path.join(process.argv[3], "bin/lib/judge-files.js"));
    const Protocol = load(path.join(__dirname, "../JarvisProtocol.js"));
    const Dispatch = load(path.join(process.argv[3], "shell/Core/Dispatch.js"));
    const Launch = load(path.join(process.argv[3], "shell/Commons/DesktopLaunch.js"));
    const Session = Protocol.Session;
    const { SessionRunner, unavailable } = require("./session-runner.js");
    const { Audio } = require("./Audio.js");
    const decoder = new StringDecoder("utf8");
    let tail = "";
    let context = null;
    let ending = false;
    let seq = 0;
    let audit = null;
    let requests = null;
    let engine = null;
    let executors = null;
    const clock = { now: () => performance.now(), set: (fn, ms) => setTimeout(fn, ms), clear: timer => clearTimeout(timer) };
    let tasks = null;
    let bridge = null;

    function teardown() {
        // The bridge ends its connections while the router can still drop their results.
        if (bridge !== null) bridge.close();
        runner.close();
        if (engine !== null) engine.close();
        if (executors !== null) executors.close();
        if (requests !== null) requests.close();
        if (audit !== null) audit.close();
        if (tasks !== null) tasks.close();
    }

    function fatal(error) {
        ending = true;
        teardown();
        void audio.close("protocol");
        refuse(error.message.startsWith("jarvis: tasks=") || error.message.startsWith("jarvis: task=")
            || error.message.startsWith("jarvis: audit=") ? 74
            : error.message.startsWith("jarvis: mute=") ? 78 : 65, error.message);
    }

    // Adapt the shared request result to the task display's text contract.
    function taskTui(args) {
        if (ending || context === null) return Promise.resolve("refused: daemon=ending");
        return new Promise(resolve => {
            requests.send("tui.run", args, 20000, result => {
                switch (result.kind) {
                case "answer": resolve(result.answer); break;
                case "busy": resolve("refused: request=tui.run reason=busy"); break;
                case "timeout": resolve("refused: request=tui.run reason=timeout"); break;
                case "refused": resolve(result.reason); break;
                default: throw new Error("jarvis: requests=result-kind");
                }
            });
        });
    }

    // hyprctl finds this session's socket from these alone.
    function hyprctlEnvironment() {
        const environment = { PATH: process.env.PATH || "/usr/bin:/bin", LANG: "C.UTF-8" };
        for (const name of ["XDG_RUNTIME_DIR", "HYPRLAND_INSTANCE_SIGNATURE"])
            if (process.env[name] !== undefined) environment[name] = process.env[name];
        return environment;
    }

    function intentIdentity(message) {
        if (context === null || message.revision !== context.revision)
            throw new Error("jarvis: protocol=identity");
    }

    function readMute() {
        let fd;
        try {
            fd = fs.openSync(path.join(context.directories.state, "mute.json"),
                fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
            if (!fs.fstatSync(fd).isFile()) throw new Error("jarvis: mute=record-not-file");
            const bytes = Buffer.alloc(65);
            const size = fs.readSync(fd, bytes, 0, bytes.length, 0);
            if (size > 64) throw new Error("jarvis: mute=record-size");
            let value;
            try { value = JSON.parse(bytes.subarray(0, size).toString("utf8")); }
            catch { throw new Error("jarvis: mute=record-json"); }
            if (value === null || typeof value !== "object" || Array.isArray(value)
                    || Object.keys(value).join(",") !== "muted" || typeof value.muted !== "boolean")
                throw new Error("jarvis: mute=record-shape");
            return value.muted;
        } catch (error) {
            if (error.code === "ENOENT") return false;
            if (error.message.startsWith("jarvis: mute=")) throw error;
            throw new Error("jarvis: mute=read-failed");
        } finally {
            if (fd !== undefined) {
                try { fs.closeSync(fd); } catch { throw new Error("jarvis: mute=read-close-failed"); }
            }
        }
    }

    function storeMute(muted) {
        const directory = context.directories.state;
        const file = path.join(directory, ".mute-" + process.pid);
        let fd;
        let owned = false;
        try {
            fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
            fd = fs.openSync(file, "wx", 0o600);
            owned = true;
            fs.writeFileSync(fd, JSON.stringify({ muted }) + "\n");
            fs.closeSync(fd);
            fd = undefined;
            fs.renameSync(file, path.join(directory, "mute.json"));
        } catch (error) {
            throw new Error("jarvis: mute=write-failed");
        } finally {
            if (fd !== undefined) {
                try { fs.closeSync(fd); } catch { throw new Error("jarvis: mute=write-close-failed"); }
            }
            if (owned) {
                try { fs.unlinkSync(file); }
                catch (error) { if (error.code !== "ENOENT") throw new Error("jarvis: mute=cleanup-failed"); }
            }
        }
    }

    function fault(reason) {
        if (!ending && context !== null) write({ v: 1, type: "audio-fault", gen: runner.state.gen,
            revision: context.revision, reason: String(reason).replace(/[\x00-\x1f\x7f]/g, " ").slice(0, 180) });
    }

    function write(message) {
        const wire = JSON.stringify(message);
        Protocol.accept(wire, "daemon");
        if (process.stdout.writableLength + Buffer.byteLength(wire + "\n") > Protocol.MAX_LINE_BYTES) {
            ioFailed("stdout", { code: "overflow" });
            return;
        }
        if (!process.stdout.write(wire + "\n")) process.stdin.pause();
    }
    const audio = new Audio({
        session: Session, environment: process.env, clock: {
            now: () => performance.now(), set: (fn, ms) => setTimeout(fn, ms), clear: timer => clearTimeout(timer)
        },
        offers: devices => {
            if (!ending && context !== null) write({ v: 1, type: "devices", gen: runner.state.gen,
                revision: context.revision, ...devices });
        },
        level: (gen, level) => {
            if (!ending && context !== null) write({ v: 1, type: "level", gen,
                revision: context.revision, level });
        },
        fault, captureSink: null, playbackSource: null
    });
    const ports = unavailable();
    ports.capture = { ...ports.capture, ...audio.capturePort };
    ports.playback = audio.playbackPort;
    ports.mute = { store: storeMute };
    ports.transcript = e => {
        if (!ending && context !== null) write({ v: 1, type: "transcript", gen: e.gen,
            revision: context.revision, role: e.role, text: e.text, stage: e.stage, rev: e.rev });
    };
    const runner = new SessionRunner(Session, ports, {
        now: () => performance.now(), set: (fn, ms) => setTimeout(fn, ms), clear: timer => clearTimeout(timer)
    }, (state, phase) => {
        audio.observe(state);
        if (engine !== null) engine.observe(state);
        if (state.gate.kind === "down") void audio.teardown("gate", ["capture", "playback"]);
        if (!ending && context !== null) write({ v: 1, type: "state", gen: state.gen,
            revision: context.revision, seq: ++seq, state, phase });
    });

    function read(chunk) {
        if (ending) return;
        try {
            const framed = Protocol.feed(tail, chunk);
            tail = framed.tail;
            for (const line of framed.lines) {
                const message = Protocol.accept(line, "shell");
                if (message.type === "intent" && message.intent === "task-stop") {
                    intentIdentity(message);
                    const task = message.task;
                    void tasks.stop(task).then(answer => {
                        if (!ending) write({ v: 1, type: "task-answer", gen: runner.state.gen,
                            revision: context.revision, task, answer });
                    });
                    continue;
                }
                if (message.type === "tui-state") {
                    intentIdentity(message);
                    tasks.tuiState(message.running);
                    continue;
                }
                if (message.type === "reply") {
                    intentIdentity(message);
                    requests.reply(message);
                    continue;
                }
                if (message.type === "indicator") {
                    if (context === null || message.revision !== context.revision)
                        throw new Error("jarvis: protocol=indicator-identity");
                    // Mapping is service lifetime input, not a turn callback.
                    // A gone observation must close capture even across gen.
                    runner.dispatch({ type: "indicator", shown: message.shown });
                    continue;
                }
                if (message.type === "intent") {
                    intentIdentity(message);
                    // Key edges are ordered input, not asynchronous completions.
                    // The observed gen can lag a down followed immediately by up.
                    if (message.intent === "confirm" || message.intent === "cancel") {
                        runner.dispatch({ type: message.intent === "cancel" ? "approval-cancel" : "confirm",
                            gen: message.gen, id: message.id, digest: message.digest, source: message.source });
                    } else {
                        const dispatch = () => {
                            runner.dispatch({ type: message.intent === "mute" ? "mute-toggle" : message.intent });
                        };
                        if (["mute", "stop"].includes(message.intent)) audit.cleanup(message.intent, dispatch);
                        else dispatch();
                    }
                    continue;
                }
                if (message.type === "shown") {
                    intentIdentity(message);
                    const hold = runner.state.approval;
                    runner.dispatch({ type: "shown", gen: message.gen, op: hold.op, id: message.id });
                    continue;
                }
                if (context !== null && (message.revision !== context.revision
                        || JSON.stringify(message.directories) !== JSON.stringify(context.directories)))
                    throw new Error("jarvis: protocol=identity");
                const first = context === null;
                let taskEvent = null;
                if (first) {
                    taskEvent = Tasks.publish(message.directories.data, __dirname);
                    // A crash between an exit record and prune can leave an
                    // extra ended task. Recovery uses the same locked writer.
                    const recovered = cp.spawnSync(process.execPath,
                        [taskEvent, "--state", message.directories.state, "--prune"], {
                            env: { PATH: process.env.PATH || "/usr/bin:/bin", LANG: "C.UTF-8" },
                            encoding: "utf8", maxBuffer: 8192
                        });
                    if (recovered.error) throw new Error("jarvis: tasks=recovery:" + recovered.error.code);
                    if (recovered.status !== 0) throw new Error("jarvis: tasks=recovery status="
                        + recovered.status + " signal=" + recovered.signal + " cause=" + recovered.stderr.trim());
                }
                context = message;
                if (first) {
                    audit = Audit.create({ state: context.directories.state });
                    const profile = () => runner.state.settings.policy ?? "standard";
                    const router = ToolRouter.create({ session: Session, state: () => runner.state,
                        dispatch: event => runner.dispatch(event), audit,
                        context: () => ({ profile: profile(), locked: context.locked, denied: null }),
                        result: value => bridge.deliver(value) || runner.ports.brain.outcome(value) });
                    // No harness brain exists yet, so no bridge session opens and no socket exists.
                    bridge = ToolBridge.create({ router, state: () => runner.state, audit,
                        directory: context.directories.runtime });
                    // Executor owners register only after their real probes.
                    Object.assign(runner.ports, router.ports);
                    requests = ShellRequests.create({ Protocol, clock, write: fields =>
                        write({ v: 1, type: "request", gen: runner.state.gen, revision: context.revision, ...fields }) });
                    executors = Executors.register(router, { find: commandFile, environment: process.env,
                        desktop: { Dispatch, Launch, request: requests.send, clock,
                            environment: hyprctlEnvironment(), commands: ["gio"].filter(onPath) } });
                    // The task executor needs an agent profile and a release port
                    // for the conversation's recipients. Neither exists yet, so
                    // TaskRunner only observes and stops recorded tasks.
                    tasks = TaskRunner.create({ directories: context.directories, engine: taskEvent, backend: __dirname,
                        settings: () => context.settings,
                        display: { run: taskTui },
                        count: count => {
                            if (!ending) write({ v: 1, type: "tasks", gen: runner.state.gen,
                                revision: context.revision, count });
                        },
                        failed: fatal,
                        clock: { now: Date.now, set: (fn, ms) => setTimeout(fn, ms).unref(), clear: timer => clearTimeout(timer) } });
                    const state = context.directories.state;
                    // cloudVision has no setting yet; "ask" is the plan's default.
                    engine = ChainedEngine.create({ session: Session, state: () => runner.state, audit, router,
                        accounts: () => new Accounts(state, process.env),
                        policy: () => ({ profile: profile(), cloudVision: "ask" }), fault });
                    runner.ports.brain = engine.brain;
                    runner.ports.capture = { ...runner.ports.capture, collect: engine.collect };
                    runner.ports.playback = engine.playback(audio.playbackPort);
                    audio.captureSink = engine.captureSink;
                    audio.playbackSource = engine.playbackSource;
                }
                if (first && readMute()) runner.dispatch({ type: "mute" });
                write({ v: 1, type: "status", gen: runner.state.gen, revision: context.revision,
                    daemon: context.locked ? "locked" : "ready" });
                // A healthy child is not permission to capture or start a tool.
                const configuration = engine.configure(context.settings);
                runner.dispatch({ type: "snapshot", locked: context.locked, engine: "chained",
                    configured: configuration.kind === "ready", settings: context.settings });
                if (first) void audio.discover().catch(error => {
                    if (!ending) audio.fault(error.message);
                });
                if (first) void tasks.observe();
            }
        } catch (error) {
            fatal(error);
        }
    }
    process.stdout.on("drain", () => { if (!ending) process.stdin.resume(); });
    function ioFailed(channel, error) {
        if (ending) return;
        ending = true;
        teardown();
        const released = audio.close(channel);
        refuse(74, "jarvis: " + channel + "=" + error.code);
        // Node's standard output can retain a blocked write after destroy.
        // Audio exits first; a failed pipe cannot keep the daemon alive.
        void released.then(() => process.exit(74));
    }
    process.stdout.on("error", error => ioFailed("stdout", error));
    process.stdin.on("error", error => ioFailed("stdin", error));
    process.stdin.on("data", chunk => read(decoder.write(chunk)));
    process.stdin.on("end", () => {
        read(decoder.end());
        if (ending) return;
        ending = true;
        teardown();
        void audio.close("lease");
        if (tail !== "") refuse(65, "jarvis: protocol=unterminated-line");
        // No child or handle holds the process alive after lease loss.
    });
}
