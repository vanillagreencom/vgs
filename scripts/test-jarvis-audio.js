#!/usr/bin/env node
// Real Audio and reducer ports, synthetic PCM. J09 owns all processes.
"use strict";
const { assert, fs, path, cp, tree, world, until, unlocked, copyBackend } = require("./fixtures/jarvis/audio.js");
const { Writable, PassThrough } = require("node:stream");
const { load } = require("../bin/lib/qml-library.js");
const Session = load(path.join(tree, "shell/plugins/vgs.jarvis/Session.js"));
const { SessionRunner, unavailable } = require("../shell/plugins/vgs.jarvis/backend/session-runner.js");
const file = path.join(tree, "shell/plugins/vgs.jarvis/backend/Audio.js");
const { Audio } = require(file);

function setup(Implementation = Audio, echo = null, sink = null, source = null, clock = null) {
    const levels = [], offers = [], faults = [];
    let frames = 0, at = 0;
    const audio = new Implementation({
        session: Session, environment: { PATH: process.env.PATH, HOME: process.env.HOME,
            XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR, VGSH_RUNNER_PID: "secret-runner",
            OPENAI_API_KEY: "fixture-key", ANTHROPIC_API_KEY: "fixture-key" },
        clock: clock || { now: () => at, set: (fn, ms) => setTimeout(fn, ms), clear: timer => clearTimeout(timer) },
        offers: value => offers.push(value),
        level: (gen, value) => levels.push({ gen, value, at }),
        fault: value => faults.push(value),
        captureSink: e => typeof sink === "function" ? sink(e)
            : sink || new Writable({ write(frame, encoding, done) { frames++; at += 10; done(); } }),
        playbackSource: () => source || new PassThrough(), echo
    });
    const ports = unavailable();
    ports.capture = { ...ports.capture, ...audio.capturePort,
        collect: () => {} }; // Speech is outside this audio lifetime surface.
    ports.playback = audio.playbackPort;
    ports.brain.send = () => {}; // No speech/brain implementation enters this audio fixture.
    const runner = new SessionRunner(Session, ports, {
        now: () => performance.now(), set: (fn, ms) => setTimeout(fn, ms), clear: timer => clearTimeout(timer)
    }, s => {
        audio.observe(s);
        if (s.gate.kind === "down") void audio.teardown("gate", ["capture", "echo", "playback"]);
    });
    const dispatch = (type, values = {}) => runner.dispatch({ type, ...values });
    dispatch("snapshot", { locked: false, configured: true, echoCancel: echo !== null,
        settings: { microphone: "", speaker: "" } });
    dispatch("indicator", { shown: true });
    return { audio, runner, dispatch, levels, offers, faults, frames: () => frames, tick: ms => { at += ms; } };
}

async function capture(w) {
    w.dispatch("talk-down");
    await until(() => w.runner.state.capture.kind === "open", "capture opens from real PCM");
    await until(() => fs.readdirSync(process.env.HOME).some(name => name.endsWith(".lock")) && !unlocked(),
        "fixture descendant actually holds its lock");
}

async function trigger(Implementation, type) {
    const w = setup(Implementation, { arguments: "fixture=true", target: "fixture.echo" });
    try {
        await capture(w);
        if (type === "mute") w.dispatch("mute");
        else if (type === "indicator") w.dispatch("indicator", { shown: false });
        else if (type === "provider") w.audio.failCapture("provider-disconnected", "");
        else if (type === "lease") w.runner.close();
        else w.dispatch("snapshot", { locked: type === "unknown" ? null : true, configured: true,
            echoCancel: true, settings: w.runner.state.settings });
        if (type === "mute") assert.equal(w.runner.state.mute.kind, "muting");
        await until(() => w.runner.state.capture.kind === "closed", type + " acknowledgment");
        assert.equal([...w.audio.children.values()].filter(owner => owner.kind !== "discovery").length, 0,
            type + " leaves no audio process");
        assert.equal(unlocked(), true, type + " leaves no detached descendant");
        if (type === "mute") assert.equal(w.runner.state.mute.kind, "on");
        if (type === "provider") assert.equal(w.runner.state.fault.reason, "provider-disconnected");
    } finally { w.runner.close(); await w.audio.close("test-end"); }
}

async function inside() {
    let controls = 0;
    for (const type of ["mute", "locked", "unknown", "indicator", "provider", "lease"])
        await trigger(Audio, type);
    const retired = setup();
    retired.runner.close();
    await retired.audio.close("lease");
    await assert.rejects(retired.audio.discover(), { message: "audio-start-refused" });
    assert.equal(retired.audio.children.size, 0);
    const w = setup();
    try {
        await capture(w);
        await until(() => w.frames() >= 15, "level samples");
        assert.ok(w.levels.length > 0);
        assert.deepEqual(w.levels[0].value, { capture: 0.5, playback: 0 });
        for (let i = 1; i < w.levels.length; i++)
            assert.ok(w.levels[i].at - w.levels[i - 1].at >= 1000 / 30);
        const argv = fs.readFileSync(path.join(process.env.HOME, "audio-argv"), "utf8").trim().split("\n").map(JSON.parse);
        assert.ok(argv.some(row => row.command === "pw-record" && row.argv.includes("fixture.mic")));
        const record = argv.find(row => row.command === "pw-record");
        assert.deepEqual(JSON.parse(record.argv[record.argv.indexOf("--properties") + 1]),
            { "node.dont-fallback": true, "node.dont-reconnect": true });
        for (const row of argv) {
            assert.equal(row.env.VGSH_RUNNER_PID, undefined);
            assert.equal(row.env.OPENAI_API_KEY, undefined);
            assert.equal(row.env.ANTHROPIC_API_KEY, undefined);
        }
        assert.deepEqual(w.offers.at(-1), {
            microphones: [{ label: "Fixture microphone", value: "fixture.mic" }],
            speakers: [{ label: "Fixture speaker", value: "fixture.speaker" }]
        });
    } finally { w.runner.close(); await w.audio.close("test-end"); }

    for (const [name, setting] of [["no-devices", ""], ["unavailable-id", "missing.mic"]]) {
        const w = setup();
        if (name === "no-devices") fs.writeFileSync(path.join(process.env.HOME, name), "");
        w.dispatch("snapshot", { locked: false, configured: true, echoCancel: false,
            settings: { microphone: setting, speaker: "" } });
        w.dispatch("talk-down");
        await until(() => w.runner.state.fault.kind === "error" && w.runner.state.capture.kind === "closed",
            "three device retries end");
        assert.equal(w.runner.state.fault.retry, 3);
        assert.equal(w.runner.state.fault.reason, "device-lost");
        assert.equal(w.runner.state.settings.microphone, setting, "never rewrite unavailable configured id");
        w.runner.close();
        await w.audio.close("test-end");
        if (name === "no-devices") fs.unlinkSync(path.join(process.env.HOME, name));
    }
    const failed = setup();
    fs.writeFileSync(path.join(process.env.HOME, "capture-exits"), "");
    failed.dispatch("talk-down");
    await until(() => failed.runner.state.fault.kind === "error" && failed.runner.state.capture.kind === "closed",
        "exiting capture gives its actual cause");
    assert.equal(failed.runner.state.fault.retry, 0);
    assert.equal(failed.runner.state.fault.reason, "capture-exit-1");
    failed.runner.close();
    await failed.audio.close("test-end");
    fs.unlinkSync(path.join(process.env.HOME, "capture-exits"));

    async function startupFailure(Implementation = Audio) {
        const w = setup(Implementation, null, () => {
            const sink = new Writable({ write(frame, encoding, done) { done(); } });
            queueMicrotask(() => sink.destroy(new Error("synthetic provider disconnect")));
            return sink;
        });
        try {
            w.dispatch("talk-down");
            await until(() => w.runner.state.fault.kind === "error" && w.runner.state.capture.kind === "closed",
                "provider loss during startup ends the capture set");
            assert.equal(w.runner.state.fault.reason, "provider-disconnected");
            assert.equal([...w.audio.children.values()].filter(owner => owner.kind !== "discovery").length, 0);
        } finally { w.runner.close(); await w.audio.close("test-end"); }
    }
    await startupFailure();

    async function retiredSink(Implementation = Audio) {
        const sinks = [];
        const w = setup(Implementation, null, () => {
            const sink = new Writable({ write(frame, encoding, done) { done(); } });
            sinks.push(sink);
            return sink;
        });
        try {
            await capture(w);
            w.dispatch("talk-up");
            await until(() => w.runner.state.capture.kind === "closed", "first capture exits");
            await capture(w);
            const before = w.runner.state.capture.op;
            sinks[0].emit("error", new Error("late retired provider callback"));
            await w.audio.release;
            assert.equal(w.runner.state.capture.kind, "open");
            assert.equal(w.runner.state.capture.op, before);
            assert.equal(w.runner.state.fault.kind, "none");
        } finally { w.runner.close(); await w.audio.close("test-end"); }
    }
    await retiredSink();

    fs.writeFileSync(path.join(process.env.HOME, "lost-before-monitor-trigger"), "");
    const earlyLoss = setup();
    try {
        earlyLoss.dispatch("talk-down");
        await until(() => earlyLoss.runner.state.fault.kind === "error" && earlyLoss.runner.state.capture.kind === "closed",
            "a stream exit before monitor removal still gets three device retries");
        assert.equal(earlyLoss.runner.state.fault.reason, "device-lost");
        assert.equal(earlyLoss.runner.state.fault.retry, 3);
    } finally {
        earlyLoss.runner.close();
        await earlyLoss.audio.close("test-end");
        for (const name of ["lost-before-monitor-trigger", "lost-before-monitor"])
            fs.rmSync(path.join(process.env.HOME, name), { force: true });
    }

    async function playback(Implementation = Audio) {
        const source = new PassThrough();
        const w = setup(Implementation, null, null, source);
        try {
            await capture(w);
            w.dispatch("final", { gen: w.runner.state.turn.gen, op: w.runner.state.turn.op, text: "fixture" });
            await until(() => w.runner.state.capture.kind === "closed", "capture ends before playback");
            w.dispatch("play", { gen: w.runner.state.turn.gen, op: w.runner.state.turn.op, interruptible: true });
            w.tick(40);
            const frame = Buffer.alloc(480);
            for (let i = 0; i < frame.length; i += 2) frame.writeInt16LE(8192, i);
            source.write(frame);
            await until(() => [...w.audio.children.values()].some(owner => owner.kind === "playback"),
                "real playback child starts");
            await until(() => !unlocked(), "playback descendant holds a lock");
            await until(() => w.levels.some(row => row.value.playback === 0.25), "playback RMS is published");
            assert.deepEqual(w.levels.at(-1).value, { capture: 0, playback: 0.25 });
            for (let i = 1; i < w.levels.length; i++)
                assert.ok(w.levels[i].at - w.levels[i - 1].at >= 1000 / 30, "combined channel rate");
            w.dispatch("interrupt");
            await until(() => w.runner.state.playback.kind === "idle", "interrupt waits for playback exit");
            assert.equal(unlocked(), true, "interrupt kills detached playback descendants");
            assert.equal(source.destroyed, true, "interrupt ends the provider audio feed");
            const calls = fs.readFileSync(path.join(process.env.HOME, "audio-argv"), "utf8").trim().split("\n").map(JSON.parse);
            assert.ok(calls.some(row => row.command === "pw-cat" && row.argv.includes("fixture.speaker")
                && row.argv.includes("20ms") && row.argv.includes("24000")));
            const cat = calls.filter(row => row.command === "pw-cat").at(-1);
            assert.deepEqual(JSON.parse(cat.argv[cat.argv.indexOf("--properties") + 1]),
                { "node.dont-fallback": true, "node.dont-reconnect": true });
        } finally { w.runner.close(); await w.audio.close("test-end"); }
    }
    await playback();

    async function overlap(Implementation = Audio, operation = "flush") {
        const source = new PassThrough();
        const w = setup(Implementation, { arguments: "fixture=true", target: "fixture.echo" }, null, source);
        try {
            w.dispatch("toggle");
            await until(() => w.runner.state.capture.kind === "open", "conversation capture opens");
            w.dispatch("final", { gen: w.runner.state.turn.gen, op: w.runner.state.turn.op, text: "fixture" });
            await until(() => w.runner.state.capture.kind === "open", "echo capture reopens after final");
            w.dispatch("play", { gen: w.runner.state.turn.gen, op: w.runner.state.turn.op, interruptible: true });
            source.write(Buffer.alloc(480));
            await until(() => [...w.audio.children.values()].some(owner => owner.kind === "playback"),
                "echo capture and playback overlap");
            w.dispatch("brain-done", { gen: w.runner.state.turn.gen, op: w.runner.state.turn.op });
            const capture = w.audio.capture;
            const echo = [...w.audio.children.values()].find(owner => owner.kind === "echo");
            const player = [...w.audio.children.values()].find(owner => owner.kind === "playback");
            assert.notEqual(capture, null);
            assert.notEqual(echo, undefined);
            if (operation === "flush") {
                w.dispatch("interrupt");
                await until(() => w.runner.state.playback.kind === "idle", "playback flush acknowledgment");
                assert.equal(w.runner.state.capture.kind, "open");
                assert.equal(w.audio.capture, capture, "flush retains the capture owner");
                assert.equal(echo.stopping, false, "flush retains echo");
                assert.equal(capture.owner.stopping, false);
                assert.equal(w.audio.children.has(echo.child), true);
                assert.equal(w.audio.children.has(capture.owner.child), true);
                assert.equal(w.audio.feed.destroyed, false);
                assert.equal(source.destroyed, true);
            } else {
                if (operation === "capture-close") w.dispatch("cancel");
                else w.audio.failCapture(operation, "");
                await until(() => w.runner.state.capture.kind === "closed", "capture release acknowledgment");
                assert.equal(w.runner.state.playback.kind, "playing");
                assert.notEqual(w.audio.playback, null, "capture release retains playback until its own acknowledgment");
                assert.equal(player.stopping, false);
                assert.equal(w.audio.children.has(player.child), true);
                assert.equal(source.destroyed, false);
                assert.equal(echo.stopping, true);
                w.dispatch("stop");
                await until(() => w.runner.state.playback.kind === "idle", "Session separately flushes playback");
                assert.equal(source.destroyed, true);
            }
        } finally { w.runner.close(); await w.audio.close("test-end"); }
    }
    for (const operation of ["flush", "capture-close", "capture-overflow", "echo-exit", "capture-refused", "discovery-failed"])
        await overlap(Audio, operation);

    async function playbackExit(Implementation = Audio) {
        fs.writeFileSync(path.join(process.env.HOME, "playback-exits"), "");
        const source = new PassThrough();
        const w = setup(Implementation, null, null, source);
        try {
            await capture(w);
            w.dispatch("final", { gen: w.runner.state.turn.gen, op: w.runner.state.turn.op, text: "fixture" });
            await until(() => w.runner.state.capture.kind === "closed", "capture closes before speech");
            w.dispatch("play", { gen: w.runner.state.turn.gen, op: w.runner.state.turn.op, interruptible: true });
            source.write(Buffer.alloc(480));
            try {
                await until(() => w.runner.state.fault.kind === "error" && w.runner.state.playback.kind === "idle",
                    "an exited player ends a provider feed that stays open");
            } catch (error) {
                assert.fail(error.message + " state=" + JSON.stringify(w.runner.state) + " children=" +
                    JSON.stringify([...w.audio.children.values()].map(owner => ({ kind: owner.kind, exit: owner.exit }))) +
                    " feed=" + JSON.stringify({ closed: source.closed, destroyed: source.destroyed }) +
                    " faults=" + JSON.stringify(w.faults));
            }
            assert.equal(w.runner.state.fault.reason, "playback-exit-1");
            assert.equal(source.destroyed, true);
            assert.equal(unlocked(), true);
        } finally {
            w.runner.close();
            await w.audio.close("test-end");
            fs.unlinkSync(path.join(process.env.HOME, "playback-exits"));
        }
    }
    await playbackExit();

    async function overflow(Implementation = Audio) {
        const sink = new Writable({ highWaterMark: 1048576, write() {} });
        const w = setup(Implementation, null, sink);
        try {
            await capture(w);
            await until(() => w.runner.state.fault.kind === "error", "bounded capture buffer faults");
            assert.equal(w.runner.state.fault.reason, "capture-overflow");
            await until(() => w.runner.state.capture.kind === "closed", "overflow waits for exits");
            assert.equal(unlocked(), true);
        } finally { w.runner.close(); await w.audio.close("test-end"); }
    }
    await overflow();

    async function discoveryOverflow(Implementation = Audio) {
        fs.writeFileSync(path.join(process.env.HOME, "huge-devices"), "");
        const w = setup(Implementation);
        try {
            await assert.rejects(w.audio.discover(), { message: "discovery-overflow" });
            assert.deepEqual(w.offers.at(-1), { microphones: [], speakers: [] });
        } finally {
            w.runner.close();
            await w.audio.close("test-end");
            fs.unlinkSync(path.join(process.env.HOME, "huge-devices"));
        }
    }
    await discoveryOverflow();

    async function cacheBound(Implementation = Audio) {
        fs.writeFileSync(path.join(process.env.HOME, "extra-properties"), "");
        const w = setup(Implementation);
        try {
            await w.audio.discover();
            assert.ok(w.audio.nodes.size > 0, "the monitor retained real offer nodes");
            for (const node of w.audio.nodes.values())
                assert.ok(Buffer.byteLength(JSON.stringify(node)) <= 1024, "arbitrary properties cannot grow the node cache");
        } finally {
            w.runner.close();
            await w.audio.close("test-end");
            fs.unlinkSync(path.join(process.env.HOME, "extra-properties"));
        }
    }
    await cacheBound();

    function monitorCalls() {
        return fs.readFileSync(path.join(process.env.HOME, "audio-argv"), "utf8").trim().split("\n")
            .map(JSON.parse).filter(row => row.command === "pw-dump" && row.argv.includes("--monitor")).length;
    }
    async function discoveryRecovery(Implementation = Audio, trigger = "monitor-exits") {
        const w = setup(Implementation);
        const marker = path.join(process.env.HOME, trigger);
        try {
            await w.audio.discover();
            const calls = monitorCalls();
            fs.writeFileSync(marker, "");
            await until(() => w.faults.length > 0 && w.offers.some(value => value.microphones.length === 0),
                "unexpected monitor failure removes untrusted offers");
            await until(() => w.offers.at(-1).microphones.length === 1, "discovery restores offers after teardown");
            await w.audio.discover();
            assert.equal(monitorCalls(), calls + 1, "one replacement monitor");
            assert.equal(w.audio.discovery.kind, "monitoring");
            assert.equal(w.faults.some(value => value.startsWith(trigger === "monitor-exits"
                ? "discovery-exit" : "discovery-framing")), true);
        } finally {
            w.runner.close();
            await w.audio.close("test-end");
            fs.rmSync(marker, { force: true });
        }
    }
    for (const trigger of ["monitor-exits", "monitor-malformed"]) await discoveryRecovery(Audio, trigger);

    async function discoveryBound(Implementation = Audio) {
        const w = setup(Implementation);
        const marker = path.join(process.env.HOME, "monitor-crashes");
        try {
            await w.audio.discover();
            const calls = monitorCalls();
            fs.writeFileSync(marker, "");
            await until(() => w.faults.some(value => value.startsWith("discovery-recovery-exhausted:")),
                "automatic monitor recovery stops at its lifetime bound");
            assert.equal(monitorCalls(), calls + 3);
            assert.equal(w.audio.discovery.kind, "failed");
            await assert.rejects(w.audio.discover(), /discovery-recovery-exhausted:/);
            assert.deepEqual(w.offers.at(-1), { microphones: [], speakers: [] });
            assert.equal(w.audio.children.size, 0);
        } finally {
            w.runner.close();
            await w.audio.close("test-end");
            fs.rmSync(marker, { force: true });
        }
    }
    await discoveryBound();

    async function discoveryClose(Implementation = Audio) {
        const timers = new Map();
        const clock = { now: () => 0, set: (fn, ms) => { const timer = {}; timers.set(timer, { fn, ms }); return timer; },
            clear: timer => timers.delete(timer) };
        const w = setup(Implementation, null, null, null, clock);
        const marker = path.join(process.env.HOME, "monitor-exits");
        try {
            await w.audio.discover();
            const calls = monitorCalls();
            fs.writeFileSync(marker, "");
            await until(() => w.audio.discovery.kind === "waiting", "monitor recovery timer is armed");
            assert.equal(timers.size, 1);
            const scheduled = [...timers.values()][0];
            w.runner.close();
            await w.audio.close("lease");
            assert.equal(timers.size, 0, "close cancels the reconnect timer");
            scheduled.fn();
            assert.equal(monitorCalls(), calls);
            assert.equal(w.audio.children.size, 0);
        } finally {
            await w.audio.close("test-end");
            fs.rmSync(marker, { force: true });
        }
    }
    await discoveryClose();

    const lost = setup();
    try {
        await capture(lost);
        fs.writeFileSync(path.join(process.env.HOME, "remove-device"), "");
        await until(() => lost.runner.state.fault.kind === "error" && lost.runner.state.capture.kind === "closed",
            "discovery removal closes capture and bounds retries");
        assert.equal(lost.runner.state.fault.retry, 3);
        assert.equal(lost.runner.state.fault.reason, "device-lost");
        assert.deepEqual(lost.offers.at(-1).microphones, []);
        assert.equal(unlocked(), true);
    } finally { lost.runner.close(); await lost.audio.close("test-end"); }

    const source = fs.readFileSync(file, "utf8");
    async function control(name, needle, replacement, check) {
        assert.equal(source.split(needle).length - 1, 1, name + " match");
        const folder = path.join(process.env.JARVIS_TEST_ROOT, name);
        copyBackend(folder);
        const changed = source.replace(needle, replacement);
        assert.notEqual(changed, source);
        fs.writeFileSync(path.join(folder, "Audio.js"), changed);
        await assert.rejects(() => check(require(path.join(folder, "Audio.js")).Audio), assert.AssertionError);
        controls++;
    }
    await control("early-muted", "return this.release;", "return Promise.resolve();", async impl => {
        let released;
        const sink = new Writable({ write(frame, encoding, done) { done(); },
            destroy(error, done) { released = () => done(error); } });
        const w = setup(impl, null, sink);
        try {
            await capture(w);
            w.dispatch("mute");
            await until(() => released !== undefined, "feed close requested");
            await new Promise(resolve => setImmediate(resolve));
            assert.equal(w.runner.state.mute.kind, "muting", "mute waits for feed and process exits");
        } finally {
            if (released) released();
            w.runner.close();
            await w.audio.close("test-end");
        }
    });
    await control("level-rate", "at - this.lastLevel >= 1000 / 30", "at - this.lastLevel >= 0", async impl => {
        const w = setup(impl);
        try {
            await capture(w);
            await until(() => w.levels.length >= 3, "mutant levels");
            assert.ok(w.levels[1].at - w.levels[0].at >= 1000 / 30);
        } finally { w.runner.close(); await w.audio.close("test-end"); }
    });
    await control("env-scrub", "this.environment = {};", "this.environment = { ...environment };", async impl => {
        const w = setup(impl);
        try {
            await capture(w);
            const lines = fs.readFileSync(path.join(process.env.HOME, "audio-argv"), "utf8").trim().split("\n").map(JSON.parse);
            assert.equal(lines.at(-1).env.OPENAI_API_KEY, undefined);
        } finally { w.runner.close(); await w.audio.close("test-end"); }
    });
    await control("capture-bound", "pcm.length > BUFFER_BYTES || feed.writableLength + pcm.length > BUFFER_BYTES",
        "false && (pcm.length > BUFFER_BYTES || feed.writableLength + pcm.length > BUFFER_BYTES)", overflow);
    await control("discovery-bound", "const DISCOVERY_BYTES = 1024 * 1024;",
        "const DISCOVERY_BYTES = 2 * 1024 * 1024;", discoveryOverflow);
    await control("playback-release", 'if (this.playbackFeed !== null)',
        'if (false && this.playbackFeed !== null)', playback);
    await control("playback-level", 'this.reportLevel(playback.e.gen, "playback", pcm);',
        'if (false) this.reportLevel(playback.e.gen, "playback", pcm);', playback);
    await control("node-cache-bound", 'this.nodes.set(node.id, { group, label: label.slice(0, 60), value });',
        'this.nodes.set(node.id, { ...props, group, label: label.slice(0, 60), value });', cacheBound);
    await control("closed-owner", 'this.lifetime.kind === "closed" || (kind !== "discovery"',
        'false || (kind !== "discovery"', async impl => {
        const w = setup(impl);
        w.runner.close();
        await w.audio.close("lease");
        try { await assert.rejects(w.audio.spawn("discovery", "pw-dump"), { message: "audio-start-refused" }); }
        finally { await w.audio.close("test-end"); }
    });
    await control("startup-provider", 'if (this.capture === capture) this.failCapture("provider-disconnected", error.message);',
        'if (false && this.capture === capture) this.failCapture("provider-disconnected", error.message);', startupFailure);
    await control("retired-provider", 'if (this.capture === capture) this.failCapture("provider-disconnected", error.message);',
        'if (true || this.capture === capture) this.failCapture("provider-disconnected", error.message);', retiredSink);
    await control("player-exit", 'this.failPlayback("playback-exit-" + (owner.exit.signal || owner.exit.code));',
        'if (false) this.failPlayback("playback-exit-" + (owner.exit.signal || owner.exit.code));', playbackExit);
    await control("device-fallback", '"node.dont-fallback": true', '"node.dont-fallback": false', playback);
    await control("device-reconnect", '"node.dont-reconnect": true', '"node.dont-reconnect": false', playback);
    await control("flush-owner", 'this.teardown("interrupt", ["playback"])',
        'this.teardown("interrupt", ["capture", "echo", "playback"])', overlap);
    await control("capture-fault-owner", 'this.teardown(reason, ["capture", "echo"])',
        'this.teardown(reason, ["capture", "echo", "playback"])', impl => overlap(impl, "capture-overflow"));
    await control("discovery-retired", 'this.discovery = waiting;',
        'if (false) this.discovery = waiting;', discoveryRecovery);
    await control("discovery-recovery-bound", "if (discovery.retries === 3)", "if (discovery.retries === 4)", discoveryBound);
    await control("discovery-close", 'if (this.discovery.kind === "waiting") this.clock.clear(this.discovery.timer);',
        'if (false && this.discovery.kind === "waiting") this.clock.clear(this.discovery.timer);', discoveryClose);
    await control("closed-discovery", 'if (this.lifetime.kind === "closed") return Promise.reject(new Error("audio-start-refused"));',
        'if (false) return Promise.reject(new Error("audio-start-refused"));', async impl => {
            const w = setup(impl);
            try {
                await w.audio.discover();
                w.runner.close();
                await w.audio.close("lease");
                await assert.rejects(w.audio.discover(), { message: "audio-start-refused" });
            } finally { await w.audio.close("test-end"); }
        });
    console.log("test-jarvis-audio: ok triggers=6 controls=" + controls);
}

world(inside).catch(error => { console.error(error); process.exitCode = 1; });
