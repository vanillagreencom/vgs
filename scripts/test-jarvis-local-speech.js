// The local speech row and adapter against a stand-in sidecar, in the J09
// world. The stand-in (fixtures/jarvis-local-speech/standin.py) is installed
// as the runtime's interpreter, so the real spawn, namespace, environment,
// resampling and wire run; no model, device or network is involved. Each
// control plants one defect in a disposable copy of LocalSpeech.js.
"use strict";
const { assert, fs, path, tree, world, until } = require("./fixtures/jarvis/audio.js");

const PLUGIN = path.join(tree, "shell/plugins/vgs.jarvis");
const STANDIN = path.join(__dirname, "fixtures/jarvis-local-speech/standin.py");
// Bounds a missing observation, not a latency.
const OBSERVE_MS = 10000;
let cases = 0;

function scratch(name) { return fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, name + "-")); }

// A plugin copy holding LocalSpeech.js with each edit applied once.
function plugin(edits = []) {
    if (edits.length === 0) return PLUGIN;
    const folder = scratch("plugin");
    fs.cpSync(path.join(PLUGIN, "backend"), path.join(folder, "backend"), { recursive: true });
    fs.copyFileSync(path.join(PLUGIN, "artifacts.json"), path.join(folder, "artifacts.json"));
    const file = path.join(folder, "backend/LocalSpeech.js");
    const source = fs.readFileSync(file, "utf8");
    let changed = source;
    for (const [needle, replacement] of edits) {
        assert.equal(changed.split(needle).length - 1, 1, "control needle matches once: " + needle);
        changed = changed.replace(needle, replacement);
    }
    assert.notEqual(changed, source);
    fs.writeFileSync(file, changed);
    return folder;
}
function row(folder) { return require(path.join(folder, "backend/LocalSpeech.js")).row; }

const worlds = [];
function alive(pid) {
    if (pid === undefined) return false;
    try { process.kill(pid, 0); return true; }
    catch (error) { if (error.code === "ESRCH") return false; throw error; }
}

// A ready runtime: the marker setup publishes and the stand-in interpreter.
function runtime(scenario, marker = {}) {
    const root = scratch("case");
    const state = path.join(root, "state"), data = path.join(root, "data"), local = path.join(data, "local");
    fs.mkdirSync(state);
    fs.mkdirSync(path.join(local, "venv/bin"), { recursive: true });
    fs.copyFileSync(STANDIN, path.join(local, "venv/bin/python"));
    fs.chmodSync(path.join(local, "venv/bin/python"), 0o700);
    fs.writeFileSync(path.join(local, "scenario.json"), JSON.stringify(scenario));
    fs.writeFileSync(path.join(state, "local-ready.json"), JSON.stringify({ schemaVersion: 1, tier: "small",
        data: fs.realpathSync(local), inputs: "0".repeat(64), ...marker }));
    const world_ = { directories: { state, data, runtime: root }, local,
        log: () => fs.existsSync(path.join(local, "log.jsonl")) ? fs.readFileSync(path.join(local, "log.jsonl"), "utf8")
            .trim().split("\n").filter(Boolean).map(line => JSON.parse(line)) : [] };
    worlds.push(world_);
    return world_;
}
function adapter(folder, world_) {
    const answer = row(folder).select({ settings: {}, accounts: () => assert.fail("no account"), directories: world_.directories });
    assert.equal(answer.kind, "ready", JSON.stringify(answer));
    return answer.open({ net: null, recipients: answer.recipients });
}

function tone(frequency, seconds, amplitude, rate = 24000) {
    const out = Buffer.alloc(rate * seconds * 2);
    for (let i = 0; i < rate * seconds; i++)
        out.writeInt16LE(Math.round(amplitude * 32767 * Math.sin(2 * Math.PI * frequency * i / rate)), 2 * i);
    return out;
}
// Capture frames as Audio's sink hands them: speech items, cut at odd sizes.
function frames(pcm, size = 4801) {
    const items = [];
    for (let at = 0; at < pcm.length; at += size) items.push({ content: pcm.subarray(at, at + size), labels: ["speech"] });
    return (async function* () { yield* items; })();
}
async function final(output) {
    const events = [];
    for await (const event of output) events.push(event);
    return events;
}
async function rejects(promise, message) {
    let timer;
    const limit = new Promise((_, reject) => { timer = setTimeout(() => reject(new assert.AssertionError({ message: "no failure observed" })), OBSERVE_MS); });
    try {
        await assert.rejects(Promise.race([promise, limit]), error => error.message === message
            || assert.fail("cause " + error.message + " != " + message));
    } finally { clearTimeout(timer); }
}
const start = log => log.find(entry => entry.start)?.start;

// Selection: every cause is keyed; only a marker for this data root and a
// declared tier is ready.
async function selection(folder) {
    const select = directories => row(folder).select({ settings: {}, accounts: null, directories });
    const bare = scratch("bare");
    assert.deepEqual(select({ state: bare, data: bare, runtime: bare }), { kind: "unconfigured", cause: "speech=local-not-set-up" });
    for (const [name, marker, detail] of [["unknown tier", { tier: "huge" }, "marker-stale"],
        ["another data root", { data: "/elsewhere" }, "marker-stale"]]) {
        const w = runtime({}, marker);
        assert.deepEqual(select(w.directories), { kind: "unconfigured", cause: "speech=local-not-ready", detail }, name);
    }
    const corrupt = runtime({});
    fs.writeFileSync(path.join(corrupt.directories.state, "local-ready.json"), "{");
    assert.deepEqual(select(corrupt.directories), { kind: "unconfigured", cause: "speech=local-not-ready", detail: "marker-json" });
    const moved = runtime({});
    fs.rmSync(moved.local, { recursive: true });
    assert.deepEqual(select(moved.directories), { kind: "unconfigured", cause: "speech=local-not-ready", detail: "ENOENT" });
    const ready = select(runtime({}).directories);
    assert.equal(ready.kind, "ready");
    assert.deepEqual(ready.recipients, [{ kind: "local", provider: "local-speech", account: "" }]);
    cases++;
}

// One utterance: the boundary the sidecar starts in, and Audio's 24 kHz
// capture reaching it as 16 kHz samples of the same tone.
async function utterance(folder) {
    const w = runtime({ utterances: [{ final: "read this local test" }] });
    process.env.JARVIS_LOCAL_SPEECH_SENTINEL = "never passed";
    const speech = adapter(folder, w);
    try {
        assert.deepEqual(await final(speech.transcribe(frames(tone(1000, 1, 0.5)))), [{ kind: "final", text: "read this local test" }]);
        const log = w.log();
        const facts = start(log);
        assert.deepEqual(facts.argv, ["-I", path.join(folder, "backend/local-speech.py"), "--state", w.directories.state,
            "--data", w.local, "--parent", String(process.pid)]);
        assert.deepEqual(facts.env, ["HOME", "LC_ALL", "PATH"], "an explicit environment");
        assert.equal(facts.ppid, process.pid);
        assert.equal(facts.pdeathsig, 9, "the daemon's death kills the sidecar");
        assert.notEqual(facts.net, fs.readlinkSync("/proc/self/ns/net"), "a private network namespace");
        const ended = log.find(entry => entry.end);
        assert.equal(ended.samples, 16000, "one second at 16 kHz");
        assert.ok(Math.abs(ended.crossings - 2000) <= 4, "a 1 kHz tone keeps its frequency: " + ended.crossings);
        assert.ok(Math.abs(ended.rms - 0.5 / Math.SQRT2) < 0.01, "and its level: " + ended.rms);
    } finally { speech.close(); delete process.env.JARVIS_LOCAL_SPEECH_SENTINEL; }
    cases++;
}

// A 9 kHz tone is above the 8 kHz band; decimation must not fold it in.
async function antiAlias(folder) {
    const w = runtime({ utterances: [{ final: "x" }] });
    const speech = adapter(folder, w);
    try {
        await final(speech.transcribe(frames(tone(9000, 1, 0.5))));
        const ended = w.log().find(entry => entry.end);
        assert.ok(ended.rms < 0.02, "folded 9 kHz energy: " + ended.rms);
    } finally { speech.close(); }
    cases++;
}

async function failures(folder) {
    for (const [name, scenario, cause] of [
        ["failed chunk", { utterances: [{ failed: "chunk-empty index=1" }] }, "jarvis: speech=local-chunk-empty index=1"],
        ["sidecar exit", { utterances: [{ exit: 70 }] }, "jarvis: speech=local-exit code=70 signal=null"],
        ["not ready", { start: "not-ready" }, "jarvis: speech=local-runtime-not-ready"],
        ["load failure", { start: "exit" }, "jarvis: speech=local-exit code=70 signal=null"],
        ["malformed frame", { start: "garbage" }, "jarvis: speech=local-protocol key=message value=invalid"],
        ["foreign id", { start: "foreign-id", utterances: [{ final: "x" }] }, "jarvis: speech=local-protocol key=id value=invalid"]]) {
        const speech = adapter(folder, runtime(scenario));
        try { await rejects(final(speech.transcribe(frames(tone(1000, 1, 0.5)))), cause); }
        catch (error) { error.message = name + ": " + error.message; throw error; }
        finally { speech.close(); }
    }
    cases++;
}

// An abandoned utterance is aborted at the sidecar; the next one still runs.
async function abort(folder) {
    const w = runtime({ utterances: [{ final: "second" }] });
    const speech = adapter(folder, w);
    try {
        let release;
        const held = new Promise(resolve => { release = resolve; });
        const first = speech.transcribe((async function* () {
            yield { content: tone(1000, 1, 0.5), labels: ["speech"] };
            await held;
        })());
        const pending = first.next();
        await first.return();
        assert.deepEqual(await pending, { value: undefined, done: true });
        release();
        assert.deepEqual(await final(speech.transcribe(frames(tone(1000, 1, 0.5)))), [{ kind: "final", text: "second" }]);
        const log = w.log();
        assert.equal(log.find(entry => "abort" in entry)?.abort, 1, "the abandoned utterance is aborted");
        assert.deepEqual(log.filter(entry => entry.end).map(entry => entry.end), [2]);
    } finally { speech.close(); }
    cases++;
}

// A sidecar that reads nothing: the backlog bound fails the utterance and
// close kills the process.
async function backlog(folder) {
    const w = runtime({ start: "deaf" });
    const speech = adapter(folder, w);
    try {
        await rejects(final(speech.transcribe(frames(Buffer.alloc(24000 * 2 * 125), 48000))), "jarvis: speech=local-backlog");
    } finally { speech.close(); }
    cases++;
}
async function close(folder) {
    const w = runtime({ start: "deaf" });
    const speech = adapter(folder, w);
    await until(() => start(w.log()) !== undefined, "the stand-in started", OBSERVE_MS);
    const pid = start(w.log()).pid;
    speech.close();
    await until(() => !alive(pid), "close ends the sidecar", OBSERVE_MS);
    cases++;
}

// Synthesis: each voice's rate becomes Audio's 24 kHz; a sentence's frames
// count what is played, in chunks within Audio's bound.
async function speaking(folder) {
    const w = runtime({ speech: [{ rate: 22050, samples: 22050, tone: 440, value: 0.5 }, { rate: 24000, samples: 30000, value: 0.25 },
        { failed: "synthesis-failed" }] });
    const speech = adapter(folder, w);
    try {
        const sentences = ["First sentence.", "Second sentence."].map(content => ({ content, labels: ["speech"] }));
        const chunks = [];
        for await (const chunk of speech.speak((async function* () { yield* sentences; })())) chunks.push(chunk);
        assert.deepEqual(chunks.map(chunk => [chunk.sentence?.text, chunk.sentence?.frames, chunk.pcm.length / 2]),
            [["First sentence.", 24000, 24000], ["Second sentence.", 30000, 24000], [undefined, undefined, 6000]]);
        const first = chunks[0].pcm;
        let crossings = 0;
        for (let i = 1; i < first.length / 2; i++) if ((first.readInt16LE(2 * i - 2) < 0) !== (first.readInt16LE(2 * i) < 0)) crossings++;
        assert.ok(Math.abs(crossings - 880) <= 4, "a 440 Hz voice keeps its pitch: " + crossings);
        assert.ok([chunks[1].pcm, chunks[2].pcm].every(pcm => pcm.equals(Buffer.alloc(pcm.length, Buffer.from([0x00, 0x20])))),
            "a 24 kHz voice passes unchanged");
        await rejects(final(speech.speak((async function* () { yield { content: "Third.", labels: [] }; })())),
            "jarvis: speech=local-synthesis-failed");
        await rejects(final(speech.speak((async function* () { yield { content: " ", labels: [] }; })())),
            "jarvis: speech=local-sentence-empty");
        assert.deepEqual(w.log().filter(entry => entry.speak).map(entry => entry.text), ["First sentence.", "Second sentence.", "Third."]);
    } finally { speech.close(); }
    cases++;
}

const CASES = { selection, utterance, antiAlias, failures, abort, backlog, close, speaking };
// Controls: name, edits to LocalSpeech.js, the case that must turn red.
const CONTROLS = [
    ["tier check", [["|| !Object.hasOwn(tiers, marker.tier) ", ""]], "selection"],
    ["data root check", [[" || marker.data !== root)", ")"]], "selection"],
    ["shared network", [['"--map-current-user", "--net", "--"', '"--map-current-user", "--"']], "utterance"],
    ["no parent-death signal", [['"setpriv", "--pdeathsig", "KILL", "--"', '"setpriv", "--"']], "utterance"],
    ["inherited environment", [["{ env: environment, stdio", "{ env: { ...process.env, ...environment }, stdio"]], "utterance"],
    ["no resampling", [["sendAudio(id, resampler.push(fromPcm(bytes)));", "sendAudio(id, fromPcm(bytes));"]], "utterance"],
    ["split sample dropped", [["carry = bytes.subarray(bytes.length - (bytes.length % 2));", "carry = Buffer.alloc(0);"]], "utterance"],
    ["no anti-alias band", [["PASSBAND * Math.min(from, to)", "PASSBAND * Math.max(from, to)"]], "antiAlias"],
    ["failure read as final", [['?.settle({ kind: "failed", error: failure(header.cause) });', '?.settle({ kind: "final", text: "" });']], "failures"],
    ["exit unobserved", [['child.on("close",', 'child.on("closed",']], "failures"],
    ["foreign id accepted", [[" || header.id > next)", ")"]], "failures"],
    ["no abort sent", [['if (life.kind !== "ended") write({ type: "abort", id });', ""]], "abort"],
    ["no backlog bound", [["if (child.stdin.writableLength > BACKLOG_BYTES) {", "if (false) {"]], "backlog"],
    ["close leaves the process", [['        child.kill("SIGKILL");\n', ""]], "close"],
    ["native frames counted", [["const pcm = toPcm(result.rate === PCM_RATE ? native :", "const pcm = toPcm(true ? native :"]], "speaking"]
];

world(async () => {
    for (const run of Object.values(CASES)) await run(PLUGIN);
    // Every adapter the real cases opened was closed: no stand-in outlives it.
    await until(() => worlds.every(w => !alive(start(w.log())?.pid)), "a sidecar outlived its adapter", OBSERVE_MS);
    let controls = 0;
    for (const [name, edits, target] of CONTROLS) {
        const folder = plugin(edits);
        const before = cases;
        let observed = null;
        await assert.rejects(() => CASES[target](folder), error => { observed = error; return true; },
            "must-fail control stayed green: " + name);
        cases = before;
        controls++;
        console.log("control=" + name + " detected: " + observed.message.split("\n")[0]);
    }
    // A control's defect can leave its stand-in running; end them all.
    for (const w of worlds) if (alive(start(w.log())?.pid)) process.kill(start(w.log()).pid, "SIGKILL");
    console.log("test-jarvis-local-speech: ok cases=" + cases + " controls=" + controls);
}, 600000);
