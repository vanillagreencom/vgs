#!/usr/bin/env node
// Disposable daemon supplies the later speech/indicator owners. Production
// code has no fixture switch. J09 remains alive while death is checked, so
// its outer namespace cannot conceal a leaked production audio descendant.
"use strict";
const { assert, fs, path, cp, tree, world, until, unlocked, copyBackend } = require("./fixtures/jarvis/audio.js");
const { once } = require("node:events");
const plugin = path.join(tree, "shell/plugins/vgs.jarvis");

function daemonCopy(name, mutant = null, half = false) {
    const folder = path.join(process.env.JARVIS_TEST_ROOT, name);
    copyBackend(path.join(folder, "backend"));
    for (const file of ["JarvisProtocol.js", "Session.js"])
        fs.copyFileSync(path.join(plugin, file), path.join(folder, file));
    let source = fs.readFileSync(path.join(folder, "backend/jarvisd.js"), "utf8");
    for (const [needle, replacement] of [
        ["captureSink: null, playbackSource: null",
            'captureSink: () => new (require("node:stream").Writable)({ write(frame, encoding, done) { done(); } }), playbackSource: null'],
        ["ports.capture = { ...ports.capture, ...audio.capturePort };",
            "ports.capture = { ...ports.capture, ...audio.capturePort, collect: () => {} };"],
        ["configured: false, settings: context.settings });",
            'configured: true, settings: context.settings });\n' +
            '                runner.dispatch({ type: "indicator", shown: true });\n' +
            '                runner.dispatch({ type: "talk-down" });']
    ]) {
        assert.equal(source.split(needle).length - 1, 1, name + " instrumentation");
        source = source.replace(needle, replacement);
    }
    if (half) {
        fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis/scripted.js"),
            path.join(folder, "backend/scripted-fixture.js"));
        const needle = "ports.playback = audio.playbackPort;";
        assert.equal(source.split(needle).length - 1, 1);
        source = source.replace(needle, needle + '\n' +
            '    const speech = require("./scripted-fixture.js").ports(process.env.HOME);\n' +
            '    ports.capture.collect = speech.capture.collect;\n' +
            '    ports.brain = speech.brain;\n' +
            '    audio.playbackSource = () => {\n' +
            '        const source = new (require("node:stream").PassThrough)();\n' +
            '        source.write(Buffer.alloc(480));\n' +
            '        const timer = setInterval(() => {\n' +
            '            if (fs.existsSync(path.join(process.env.HOME, "audio-complete"))) source.end();\n' +
            '        }, 10);\n' +
            '        source.once("close", () => clearInterval(timer));\n' +
            '        return source;\n' +
            '    };');
    }
    fs.writeFileSync(path.join(folder, "backend/jarvisd.js"), source);
    if (mutant) {
        const file = path.join(folder, "backend/audio-child.py");
        const original = fs.readFileSync(file, "utf8");
        let changed = original;
        for (const [needle, replacement] of mutant) {
            assert.equal(changed.split(needle).length - 1, 1);
            changed = changed.replace(needle, replacement);
        }
        assert.notEqual(changed, original);
        fs.writeFileSync(file, changed);
    }
    return path.join(folder, "backend/jarvisd.js");
}

async function run(file, trigger) {
    const child = cp.spawn("node", [file, "--tree", tree], {
        env: { PATH: process.env.PATH, HOME: process.env.HOME, XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR },
        stdio: ["pipe", "pipe", "pipe"]
    });
    const closed = once(child, "close");
    let output = "", error = "";
    child.stdout.on("data", data => { output += data; });
    child.stderr.on("data", data => { error += data; });
    child.stdin.on("error", e => { if (e.code !== "EPIPE") throw e; });
    const half = trigger.startsWith("speaking-");
    const hello = locked => JSON.stringify({ v: 1, type: "hello", gen: 0,
        settings: { mode: half ? "toggle" : "hold", microphone: "", speaker: "", brain: "" },
        keys: { talk: null, mute: null, stop: null }, locked,
        directories: { state: process.env.HOME, data: process.env.HOME, runtime: process.env.XDG_RUNTIME_DIR },
        revision: "a".repeat(64) }) + "\n";
    try {
        child.stdin.write(hello(false));
        await until(() => output.includes('"phase":"listening"'), "real daemon captured fixture PCM: " + error);
        await until(() => !unlocked(), "detached child reached its lock");
        if (half) {
            const state = () => output.split("\n").slice(0, -1).map(JSON.parse)
                .filter(row => row.type === "state").at(-1).state;
            fs.writeFileSync(path.join(process.env.HOME, "final"), "");
            await until(() => state().turn.kind === "thinking" && state().capture.kind === "open",
                "actual daemon reopens conversation capture while thinking");
            fs.writeFileSync(path.join(process.env.HOME, "brain"), "");
            await until(() => state().playback.kind === "playing" && state().playback.admission.kind === "started"
                && state().turn.kind === "none", "actual daemon reaches playback");
            assert.equal(state().duplex.kind, "half");
            assert.equal(state().capture.kind, "closed", "daemon closes recorder before speech");
            const intent = name => child.stdin.write(JSON.stringify({ v: 1, type: "intent", gen: state().gen,
                revision: "a".repeat(64), intent: name }) + "\n");
            if (trigger === "speaking-complete") {
                fs.writeFileSync(path.join(process.env.HOME, "audio-complete"), "");
                await until(() => state().capture.kind === "open", "actual daemon resumes permitted conversation");
            } else if (trigger === "speaking-mute") {
                intent("mute");
                await until(() => state().playback.kind === "idle" && state().mute.kind === "on",
                    "mute ends playback without restarting capture");
                assert.equal(state().capture.kind, "closed");
                await until(() => unlocked(), "mute releases every audio child");
            } else if (trigger === "speaking-lock") {
                child.stdin.write(hello(true));
                await until(() => state().gate.reason === "locked" && state().playback.kind === "idle",
                    "lock ends playback");
                assert.equal(state().capture.kind, "closed");
                await until(() => unlocked(), "lock releases every audio child");
            } else if (trigger === "speaking-kill") child.kill("SIGKILL");
            else if (trigger !== "speaking-lease") throw new Error("daemon fixture trigger: " + trigger);
        }
        if (trigger === "kill") child.kill("SIGKILL");
        else if (trigger === "lock") {
            child.stdin.write(hello(true));
            await until(() => unlocked(), "lock released all audio children");
            child.stdin.end();
        } else if (trigger !== "speaking-kill") child.stdin.end();
        const [code, signal] = await closed;
        if (trigger === "kill" || trigger === "speaking-kill") assert.equal(signal, "SIGKILL");
        else { assert.equal(signal, null); assert.equal(code, 0, error); }
        await until(() => unlocked(), trigger + " left an audio descendant");
        assert.equal(unlocked(), true);
    } finally {
        if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
        for (const marker of ["final", "brain", "audio-complete", "mute.json"])
            fs.rmSync(path.join(process.env.HOME, marker), { force: true });
    }
}

async function inside() {
    const file = daemonCopy("audio-daemon");
    for (const trigger of ["lease", "lock", "kill"]) await run(file, trigger);
    const half = daemonCopy("half-daemon", null, true);
    for (const trigger of ["speaking-complete", "speaking-mute", "speaking-lock", "speaking-lease", "speaking-kill"])
        await run(half, trigger);
    const admission = daemonCopy("half-admission-control", null, true);
    const sessionFile = path.resolve(admission, "../../Session.js");
    const sessionSource = fs.readFileSync(sessionFile, "utf8");
    const admissionNeedle = '&& s.playback.kind === "idle"';
    assert.equal(sessionSource.split(admissionNeedle).length - 1, 1);
    const admissionChanged = sessionSource.replace(admissionNeedle, '&& (true || s.playback.kind === "idle")');
    assert.notEqual(admissionChanged, sessionSource);
    fs.writeFileSync(sessionFile, admissionChanged);
    await assert.rejects(() => run(admission, "speaking-complete"), assert.AssertionError);
    // No audio program may run if setpriv's installation happened after the
    // parent died. A wrong expected PID reaches the same bootstrap refusal.
    const bootstrap = path.join(plugin, "backend/audio-child.py");
    const result = cp.spawnSync("setpriv", ["--pdeathsig", "KILL", "--", "python3", "-I",
        bootstrap, "outer", "99999999", "pw-record"], {
        env: { PATH: process.env.PATH, HOME: process.env.HOME }, encoding: "utf8"
    });
    assert.equal(result.status, 70);
    assert.equal(result.stderr.trim(), "jarvis: audio-child=parent-ended");
    async function wrongParent(file) {
        const child = cp.spawn("setpriv", ["--pdeathsig", "KILL", "--", "python3", "-I",
            file, "outer", "99999999", "pw-record"], {
            env: { PATH: process.env.PATH, HOME: process.env.HOME },
            stdio: ["pipe", "pipe", "pipe", "pipe", "pipe"]
        });
        let error = "";
        child.stdout.resume();
        child.stdio[4].resume();
        child.stderr.on("data", data => { error += data; });
        child.stdio[3].on("error", e => { if (!["EPIPE", "ECONNRESET"].includes(e.code)) throw e; });
        const closed = once(child, "close");
        // Bound a bootstrap that wrongly starts audio instead of refusing.
        const timeout = setTimeout(() => child.kill("SIGKILL"), 2000);
        try {
            child.stdio[3].write("S");
            const [code, signal] = await closed;
            assert.equal(signal, null);
            assert.equal(code, 70);
            assert.equal(error.trim(), "jarvis: audio-child=parent-ended");
        } finally {
            clearTimeout(timeout);
            child.stdio[3].destroy();
            child.stdin.destroy();
            if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
        }
    }
    await wrongParent(bootstrap);
    const parentFolder = path.join(process.env.JARVIS_TEST_ROOT, "parent-control");
    copyBackend(parentFolder);
    const parentFile = path.join(parentFolder, "audio-child.py");
    const source = fs.readFileSync(parentFile, "utf8");
    const parentNeedle = "if os.getppid() != int(parent):";
    assert.equal(source.split(parentNeedle).length - 1, 1);
    const changed = source.replace(parentNeedle, "if False and os.getppid() != int(parent):");
    assert.notEqual(changed, source);
    fs.writeFileSync(parentFile, changed);
    await assert.rejects(() => wrongParent(parentFile), assert.AssertionError);

    const mutant = daemonCopy("no-pid-namespace", [
        ['"--pid", "--fork",', '"--fork",'],
        ['mode != "init" or os.getpid() != 1', 'mode != "init" or (False and os.getpid() != 1)']
    ]);
    // Let the same commands run without the PID boundary. The detached lock
    // survives daemon death, and the unchanged lifetime assertion turns red.
    await assert.rejects(() => run(mutant, "kill"), assert.AssertionError);
    console.log("test-jarvis-audio-daemon: ok triggers=8 controls=3 startup-race=refused");
}
world(inside).catch(error => { console.error(error); process.exitCode = 1; });
