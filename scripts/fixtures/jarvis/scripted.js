// Private scripted ports for the v1 Session effect contract, 2026-09-30.
// No audio, provider, socket or tool runs. File gates advance callbacks only.
"use strict";
const fs = require("node:fs");
const path = require("node:path");

function ports(root) {
    fs.mkdirSync(root, { recursive: true });
    const waiting = new Map();
    let collect = null;
    const record = (kind, values) => fs.appendFileSync(path.join(root, "effects.jsonl"),
        JSON.stringify({ ...values, kind }) + "\n");
    const wait = (gate, done) => waiting.set(gate, done);
    const timer = setInterval(() => {
        for (const [gate, done] of waiting) {
            const file = path.join(root, gate);
            if (!fs.existsSync(file)) continue;
            fs.unlinkSync(file);
            waiting.delete(gate);
            done();
        }
        const final = path.join(root, "final");
        if (collect !== null && fs.existsSync(final)) {
            fs.unlinkSync(final);
            const done = collect;
            collect = null;
            done("final", "scripted utterance");
        }
    }, 10); // Poll explicit gates, not a simulated provider latency.
    timer.unref();
    process.stdin.once("end", () => clearInterval(timer));
    return {
        capture: {
            open: (e, done) => { record("capture-open", e); done(); },
            collect: (e, done) => { record("collect", e); collect = done; },
            close: (e, done) => {
                record("capture-close", e);
                const final = collect;
                collect = null;
                const finish = () => { done(); if (final !== null) final("final", "scripted utterance"); };
                if (fs.existsSync(path.join(root, "hold-close"))) wait("close", finish);
                else finish();
            }
        },
        brain: {
            send: (e, done) => {
                record("brain-send", e);
                wait("brain", () => {
                    record("brain-callback", e);
                    done("play", { interruptible: true }); done("brain-done");
                });
            },
            cancel: (e, done) => {
                record("brain-cancel", e);
                const late = waiting.get("brain");
                waiting.delete("brain");
                if (late !== undefined) wait("late-brain", late);
                done();
            },
            close: e => { record("brain-close", e); waiting.delete("brain"); },
            outcome: () => { throw new Error("scripted: unexpected-tool"); }
        },
        playback: {
            start: (e, done) => {
                record("playback-start", e);
                wait("played", () => { record("playback-callback", e); done(); });
            },
            flush: (e, done) => {
                record("playback-flush", e);
                const late = waiting.get("played");
                waiting.delete("played");
                if (late !== undefined) wait("late-played", late);
                done();
            }
        },
        tools: {
            start: () => { throw new Error("scripted: unexpected-tool"); },
            cancel: () => { throw new Error("scripted: unexpected-tool"); },
            outcome: () => { throw new Error("scripted: unexpected-tool"); },
            sync: () => {}, close: () => {}
        },
        approval: {
            show: () => { throw new Error("scripted: unexpected-approval"); },
            end: () => { throw new Error("scripted: unexpected-approval"); },
            refused: () => { throw new Error("scripted: unexpected-approval"); }
        }
    };
}

// Install only in a disposable daemon. The installed product has no fixture
// option, environment switch or import into scripts/.
function instrument(file, root) {
    const source = fs.readFileSync(file, "utf8");
    const changes = [
        ['ports.playback = audio.playbackPort;',
            'ports.playback = audio.playbackPort;\n    Object.assign(ports, require("./scripted-fixture.js").ports(' + JSON.stringify(root) + '));'],
        ['configured: false, settings: context.settings',
            'configured: true, settings: context.settings'],
        ['runner.dispatch({ type: "snapshot", locked: context.locked,',
            'runner.dispatch({ type: "indicator", shown: true });\n                runner.dispatch({ type: "snapshot", locked: context.locked,']
    ];
    let changed = source;
    for (const [needle, value] of changes) {
        if (changed.split(needle).length !== 2) throw new Error("scripted: instrumentation-match=" + needle);
        changed = changed.replace(needle, value);
    }
    if (changed === source) throw new Error("scripted: unchanged");
    fs.copyFileSync(__filename, path.join(path.dirname(file), "scripted-fixture.js"));
    fs.writeFileSync(file, changed);
}

module.exports = { ports, instrument };
if (require.main === module) instrument(process.argv[2], process.argv[3]);
