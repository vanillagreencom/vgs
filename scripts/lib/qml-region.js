// Evaluating the decision region a QML file marks off, for the tests that need
// to run it. Separate from scripts/lib/qml-source.js on purpose: reading source
// is safe, running it is the part with a threat model.
//
// The enforceable bound is a PROCESS, not anything in this process. A suite that
// evaluates a region re-execs itself through guardChild(), and the parent kills
// the child on a wall clock. In-process bounds kept being bypassed — a
// synchronous timeout does not cover a microtask, and the escape surface moved
// every time it was patched — so the timeouts below stay only as a cheap first
// stop, and the kill is what actually holds.

"use strict";

const assert = require("node:assert/strict");
const vm = require("node:vm");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

// Building the exports walks the whole region; a call is one pure decision over
// a small input, so it gets a much shorter leash. Both are overridable per call
// so the self-test's own timeout cases cost milliseconds rather than seconds.
const BUILD_TIMEOUT_MS = 5000;
const CALL_TIMEOUT_MS = 1000;
// The wall clock the PARENT enforces on a suite that evaluates a region. Long
// enough that an ordinary run (well under a second) never approaches it, short
// enough that a hang is a fast red rather than a job timeout.
const CHILD_TIMEOUT_MS = Number(process.env.VGS_REGION_CHILD_TIMEOUT_MS || 20000);

// Re-exec the calling suite as a child process the parent can kill on a wall
// clock, and return only in that child. The FIRST statement of any suite that
// evaluates a region calls this.
//
// A process is the bound that holds. An in-process timeout covers the
// synchronous call and nothing else: a function that schedules
// `Promise.resolve().then(() => { while (true) {} })` and returns normally
// finishes inside every such timeout and then hangs Node from the microtask
// queue. One kill closes that, an infinite loop and runaway allocation together.
function guardChild(bounds) {
    if (process.env.VGS_REGION_CHILD === "1")
        return;
    const script = process.argv[1];
    const limit = (bounds && bounds.timeout) || CHILD_TIMEOUT_MS;
    const run = spawnSync(process.execPath, [script, ...process.argv.slice(2)], {
        stdio: "inherit",
        timeout: limit,
        killSignal: "SIGKILL",
        env: Object.assign({}, process.env, { VGS_REGION_CHILD: "1" })
    });
    if (run.signal === "SIGKILL" || run.error) {
        process.stderr.write(
            `${script}: killed after ${limit}ms — the extracted region did not finish.\n` +
            "A hang is the failure mode a passing suite cannot be told from a slow one, " +
            "so it is a hard kill rather than an in-process timeout.\n");
        process.exit(1);
    }
    process.exit(run.status === null ? 1 : run.status);
}

// Evaluate the decision region a QML file marks off.
//
// NOT A SANDBOX, and nothing here should be read as one: `node:vm` isolates
// globals, not the process. What the context and timeouts below buy is a cheap
// first stop — `process`, `require`, `fetch`, `setTimeout` and Node's `console`
// are absent from it; code generation is off, so `eval` and the `Function`
// constructor throw; building the exports and each call run under their own
// timeout; only primitives cross in either direction. What they do NOT buy is
// containment: the enforceable bound is the parent's kill in guardChild().
//
// The exposure it mitigates is real: `new Function` ran this text in the CI
// process with full ambient authority, and ci.yml triggers on plain
// `pull_request` with no fork guard on a public repo, so a stranger's fork PR
// reaches it.
function regionOf(source, marker, label) {
    const marked = source.match(
        new RegExp(`// BEGIN ${marker}\\n([\\s\\S]*?)// END ${marker}`)
    );
    assert.ok(marked, `${label} must carry the ${marker} markers`);
    return marked[1];
}

function evaluateMarked(source, marker, names, label, bounds) {
    const region = regionOf(source, marker, label);
    const buildMs = (bounds && bounds.build) || BUILD_TIMEOUT_MS;
    const callMs = (bounds && bounds.call) || CALL_TIMEOUT_MS;
    // console is Node's, not an intrinsic: shadowed so the region cannot reach it.
    // codeGeneration off makes eval and the Function constructor throw, so the
    // region cannot build new code at runtime.
    const context = vm.createContext({ console: undefined, __argsJson: "[]" },
        { codeGeneration: { strings: false, wasm: false } });

    // The region and a dispatcher are defined INSIDE the context. Nothing hands a
    // host reference to a context function back out, because calling one from the
    // host runs it outside every timeout: a `while (true) {}` in any exported
    // function then hangs the CI process until the job's own timeout, which a fork
    // PR can trigger by editing a QML file. So each CALL is a `runInContext` with
    // its own bound, and the construction timeout is no longer the only one.
    vm.runInContext(
        `${region}\nvar __exports = { ${names.join(", ")} };\n` +
        "var __call = function (name) {\n" +
        "    var result = __exports[name].apply(null, JSON.parse(__argsJson));\n" +
        "    return JSON.stringify({ v: result });\n" +
        "};",
        context, { filename: `${label}:${marker}`, timeout: buildMs });

    // Arguments cross as ONE JSON string and results come back as one: a host
    // object handed into the context would carry the host's own intrinsics with
    // it — `arg.constructor.constructor` is the host `Function`, in a realm where
    // code generation is allowed — and a context object read from the host is the
    // same story in reverse. Primitives only, both ways.
    const out = {};
    for (const name of names) {
        out[name] = (...args) => {
            context.__argsJson = JSON.stringify(args === undefined ? [] : args);
            const answer = vm.runInContext(`__call(${JSON.stringify(name)})`, context,
                { filename: `${label}:${marker}:${name}`, timeout: callMs });
            return JSON.parse(answer).v;
        };
    }
    return out;
}

module.exports = { regionOf, evaluateMarked, guardChild };

// The self-test a library with no executable bit cannot run for itself;
// scripts/test-ai-usage-provider.js runs it before it evaluates anything.
module.exports.selfTest = function selfTest() {
    // --- the bound that actually holds: the parent's kill ---
    //
    // The bypass that ended the in-process approach: an exported function that
    // schedules a non-terminating microtask and RETURNS NORMALLY finishes inside
    // every runInContext timeout, then hangs Node from the microtask queue. A
    // suite behind guardChild() is killed anyway, because the bound is a process.
    {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vgs-region-guard-"));
        try {
            const suite = path.join(dir, "suite.js");
            fs.writeFileSync(suite, [
                `const { evaluateMarked, guardChild } = require(${JSON.stringify(__filename)});`,
                "guardChild();",
                "const region = ['// BEGIN T',",
                "    'function boom() { Promise.resolve().then(function () { while (true) {} });'",
                "    + ' return 1; }',",
                "    '// END T'].join('\\n');",
                "const { boom } = evaluateMarked(region, 'T', ['boom'], 'guard-self-test');",
                "console.log('call returned', boom());"
            ].join("\n"));

            const started = Date.now();
            const run = spawnSync(process.execPath, [suite], {
                encoding: "utf8",
                timeout: 20000,
                killSignal: "SIGKILL",
                env: Object.assign({}, process.env, {
                    VGS_REGION_CHILD: "",
                    VGS_REGION_CHILD_TIMEOUT_MS: "1000"
                })
            });
            const elapsed = Date.now() - started;

            assert.notEqual(run.status, 0,
                "a suite whose region hangs from a microtask must FAIL, not pass and hang");
            assert.ok(/killed after/.test(run.stderr || ""),
                `the parent must report the kill; stderr was ${JSON.stringify(run.stderr)}`);
            assert.ok(elapsed < 8000,
                `killed after ${elapsed}ms — the wall clock has to bound it, since a hang is the ` +
                "one failure mode a passing suite cannot be told from a slow one");
        } finally {
            fs.rmSync(dir, { recursive: true, force: true });
        }
    }

    // The in-process bounds below are a cheap first stop, not containment: they
    // close the casual paths, and the kill above is what holds when they do not.
    {
        const region = names => ["// BEGIN SELF TEST", names, "// END SELF TEST"].join("\n");
        const ok = evaluateMarked(
            region("function two() { return Math.max(1, JSON.parse('2')); }\n" +
                   "function shaped() { return { pct: 2, slots: [{ ok: true }] }; }"),
            "SELF TEST", ["two", "shaped"], "self-test");
        assert.equal(ok.two(), 2, "the intrinsics the decision code uses are there");
        assert.deepEqual(ok.shaped(), { pct: 2, slots: [{ ok: true }] },
            "and a value built in the context comes back as host data, or every deepEqual in " +
            "the suites would fail on the realm rather than on the value");

        for (const planted of [
            "process.exit(0);",
            "require('node:fs');",
            "fetch('http://example.invalid');",
            "globalThis.process.env.HOME;"
        ]) {
            assert.throws(
                () => evaluateMarked(region(`${planted}\nfunction f() {}`), "SELF TEST", ["f"],
                    "self-test"),
                /is not defined|Cannot read properties of undefined/,
                `\`${planted}\` planted in the marked region must be REJECTED, not executed — ` +
                "that region comes from a repo file, and a fork PR runs this suite on the runner"
            );
        }
        const brief = { build: 200, call: 200 };
        assert.throws(() => evaluateMarked(region("while (true) {}\nfunction f() {}"),
            "SELF TEST", ["f"], "self-test", brief), /timed out/,
            "a loop planted at the region's top level must time out rather than hang CI");

        // The one that matters most: a loop inside an EXPORTED function. Every
        // call is its own bounded run, because a host reference to a context
        // function would be called outside every timeout — a hang, which is the
        // single failure mode a green suite cannot tell from slowness. Asserted
        // on a WALL CLOCK for that reason, not merely on an eventual error.
        {
            const looping = evaluateMarked(
                region("function spin() { while (true) {} }\nfunction fine() { return 1; }"),
                "SELF TEST", ["spin", "fine"], "self-test", brief);
            assert.equal(looping.fine(), 1, "an ordinary call still answers");
            const started = Date.now();
            assert.throws(() => looping.spin(), /timed out/,
                "a call into a non-terminating exported function must be cut off");
            const elapsed = Date.now() - started;
            assert.ok(elapsed < brief.call * 5,
                `the call was cut off after ${elapsed}ms; the bound is per CALL, so this must ` +
                "fail fast rather than run until the CI job's own timeout");
        }
        for (const generated of ["eval('1');", "(function () {}).constructor('return 1')();"]) {
            assert.throws(
                () => evaluateMarked(region(`${generated}\nfunction f() {}`), "SELF TEST", ["f"],
                    "self-test"),
                /Code generation from strings disallowed/,
                `\`${generated}\` must throw: the region may not build new code at runtime`
            );
        }
    }
};
