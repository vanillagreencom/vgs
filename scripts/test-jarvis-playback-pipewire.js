#!/usr/bin/env node
// Real PCM read from a private null sink's monitor, never submitted-byte evidence.
// Acceptance: at most the plan's 60 ms lead plus this graph's 10 ms period.
// This is a design target, not a benchmark-derived latency budget.
"use strict";
const { assert, fs, path, cp, tree, world, until, Audio, setup, control } = require("./fixtures/jarvis/playback.js");
const { Readable } = require("node:stream");
const { once } = require("node:events");

async function privateAudio(run) {
    const root = process.env.JARVIS_TEST_ROOT;
    const config = path.join(root, "pcm-config");
    const tools = path.join(root, "pcm-tools");
    fs.mkdirSync(config, { recursive: true });
    fs.mkdirSync(tools, { recursive: true });
    fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis/playback.conf"), path.join(config, "pcm.conf"));
    // Client ports use the documented auto-port configuration. No session
    // manager runs, so the test itself links only this graph's named ports.
    fs.writeFileSync(path.join(config, "client.conf"), `
context.properties = { support.dbus = false }
context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert audio.adapt = audioconvert/libspa-audioconvert support.* = support/libspa-support }
context.modules = [ { name = libpipewire-module-protocol-native } { name = libpipewire-module-client-node } { name = libpipewire-module-adapter } ]
stream.properties = { adapter.auto-port-config = { mode = dsp position = preserve } }
`);
    for (const name of ["pw-cat", "pw-dump"])
        fs.writeFileSync(path.join(tools, name), "#!/bin/bash\nexport PIPEWIRE_CONFIG_DIR=" +
            JSON.stringify(config) + '\nexport PIPEWIRE_CONFIG_NAME=client.conf\nexec /usr/bin/' + name + ' "$@"\n',
        { mode: 0o700 });
    const environment = {
        PATH: tools + ":" + process.env.PATH, HOME: process.env.HOME,
        XDG_CONFIG_HOME: process.env.XDG_CONFIG_HOME, XDG_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR,
        PIPEWIRE_RUNTIME_DIR: process.env.XDG_RUNTIME_DIR, PIPEWIRE_REMOTE: "jarvis-pcm",
        PIPEWIRE_CONFIG_DIR: config, PIPEWIRE_CONFIG_NAME: "client.conf", LANG: "C", LC_ALL: "C"
    };
    const server = cp.spawn("/usr/bin/pipewire", ["-c", "pcm.conf"], {
        env: { ...environment, PIPEWIRE_CONFIG_NAME: "pcm.conf" }, stdio: ["ignore", "pipe", "pipe"]
    });
    const closed = once(server, "close");
    let diagnostic = "";
    server.stdout.resume();
    server.stderr.on("data", data => { diagnostic += data; });
    try {
        await until(() => {
            assert.equal(server.exitCode, null, diagnostic);
            return fs.existsSync(path.join(environment.PIPEWIRE_RUNTIME_DIR, "jarvis-pcm"));
        }, "private PipeWire starts: " + diagnostic);
        const dump = () => {
            const result = cp.spawnSync("/usr/bin/pw-dump", [], { env: environment, encoding: "utf8", timeout: 5000 });
            assert.equal(result.status, 0, result.stderr);
            return JSON.parse(result.stdout);
        };
        const initial = dump();
        const nodes = initial.filter(node => node.type === "PipeWire:Interface:Node");
        assert.deepEqual(nodes.map(node => node.info.props["node.name"]).sort(), ["fixture.speaker", "jarvis-driver"],
            "the private server owns no hardware node");
        await run(environment, dump);
    } finally {
        if (server.exitCode === null && server.signalCode === null) server.kill("SIGTERM");
        await closed;
    }
}

async function interrupt(Implementation = Audio) {
    await privateAudio(async (environment, dump) => {
        // pw-cat records with buffered stdio. Disable that buffer so delivery
        // timestamps describe graph periods, not a later stdout block flush.
        const recorder = cp.spawn("/usr/bin/stdbuf", ["-o0", "/usr/bin/pw-cat", "--record", "--raw", "--rate", "24000",
            "--channels", "1", "--format", "s16", "--latency", "10ms", "--target", "0",
            "--properties", '{"node.name":"jarvis-monitor"}', "-"], {
            env: environment, stdio: ["ignore", "pipe", "pipe"]
        });
        const recorderClosed = once(recorder, "close");
        let diagnostic = "", cut = false, cutAt = 0, audibleAt = 0;
        let before = 0, after = 0, quiet = 0, tail = Buffer.alloc(0);
        recorder.stderr.on("data", data => { diagnostic += data; });
        recorder.stdout.on("data", data => {
            const pcm = Buffer.concat([tail, data]);
            tail = pcm.subarray(pcm.length - pcm.length % 2);
            for (let i = 0; i + 1 < pcm.length; i += 2) {
                const audible = Math.abs(pcm.readInt16LE(i)) > 100;
                if (!cut) { if (audible) before++; }
                else if (audible) { after++; quiet = 0; audibleAt = performance.now(); }
                else quiet++;
            }
        });
        const tone = Buffer.alloc(960);
        for (let i = 0; i < tone.length; i += 2) tone.writeInt16LE(8192, i);
        const source = new Readable({ highWaterMark: 960, read() { this.push(tone); } });
        const w = setup(source, { now: () => performance.now(), set: (fn, ms) => setTimeout(fn, ms),
            clear: timer => clearTimeout(timer) }, Implementation, environment);
        const running = w.start();
        try {
            await until(() => w.audio.playback !== null && w.audio.playback.kind === "feeding", "real player starts");
            let ports;
            await until(() => {
                assert.equal(recorder.exitCode, null, diagnostic);
                ports = dump().filter(object => object.type === "PipeWire:Interface:Port");
                return ports.some(port => port.info.props["port.name"] === "input_MONO")
                    && ports.filter(port => port.info.props["port.name"] === "output_MONO").length === 1
                    && ports.some(port => port.info.props["port.name"] === "monitor_MONO");
            }, "private graph exposes player, sink monitor and recorder ports");
            const port = name => {
                const matches = ports.filter(port => port.info.props["port.name"] === name);
                assert.equal(matches.length, 1, name + " is unambiguous");
                return String(matches[0].id);
            };
            const link = (out, input) => {
                const result = cp.spawnSync("/usr/bin/pw-link", [out, input], {
                    env: environment, encoding: "utf8", timeout: 5000
                });
                assert.equal(result.status, 0, result.stderr);
            };
            const inputPorts = ports.filter(port => port.info.props["port.direction"] === "in");
            // The sink's playback port and the recorder's capture port have
            // distinct documented names. No default-device policy is involved.
            assert.equal(inputPorts.length, 2);
            link(port("output_MONO"), port("playback_MONO"));
            link(port("monitor_MONO"), port("input_MONO"));
            await until(() => before >= 4800, "actual null-sink PCM reaches the monitor");
            cutAt = performance.now();
            cut = true;
            const flushed = w.flush();
            await until(() => {
                assert.ok(after <= 1680, "actual audio after interrupt exceeds 60 ms plus the 10 ms period: " + after);
                assert.ok(audibleAt === 0 || audibleAt - cutAt <= 70,
                    "the last actual audio arrives past the interrupt-to-silence target: " + (audibleAt - cutAt));
                return quiet >= 2400;
            }, "actual audio becomes silent after interrupt");
            await flushed;
            await running;
            assert.equal(source.destroyed, true);
            assert.equal(w.audio.children.size, 0);
            assert.deepEqual(w.failures, []);
            assert.ok(before >= 4800);
            assert.ok(after <= 1680);
            console.log("private-pipewire: before_frames=" + before + " after_frames=" + after
                + " after_ms=" + (after / 24).toFixed(3) + " last_audio_ms="
                + (audibleAt === 0 ? 0 : audibleAt - cutAt).toFixed(3) + " period_ms=10 limit_frames=1680");
        } finally {
            await w.audio.close("test-end");
            if (recorder.exitCode === null && recorder.signalCode === null) recorder.kill("SIGTERM");
            await recorderClosed;
        }
    });
}

async function inside() {
    for (const executable of ["pipewire", "pw-cat", "pw-dump", "pw-link", "stdbuf"])
        if (!fs.existsSync("/usr/bin/" + executable)) {
            console.error("test-jarvis-playback-pipewire: not-verified missing=" + executable);
            process.exitCode = 77;
            return;
        }
    await interrupt();
    await control("actual-audio-flush", 'const release = this.teardown("interrupt", ["playback"]);',
        'const release = false ? this.teardown("interrupt", ["playback"]) : Promise.resolve();', interrupt);
    await control("actual-audio-present", "const flowing = owner.child.stdin.write(pcm);",
        "const flowing = owner.child.stdin.write(Buffer.alloc(pcm.length));", interrupt);
    console.log("test-jarvis-playback-pipewire: ok controls=2");
}
world(inside).catch(error => { console.error(error); process.exitCode = 1; });
