// Evaluating the decision region a QML file marks off, for the tests that need
// to run it. Separate from scripts/lib/qml-source.js on purpose: reading source
// is safe, running it is the part with a threat model.

"use strict";

const assert = require("node:assert/strict");
const vm = require("node:vm");

// Building the exports walks the whole region; a call is one pure decision over
// a small input, so it gets a much shorter leash. Both are overridable per call
// so the self-test's own timeout cases cost milliseconds rather than seconds.
const BUILD_TIMEOUT_MS = 5000;
const CALL_TIMEOUT_MS = 1000;

// Evaluate the decision region a QML file marks off.
//
// NOT A SECURITY BOUNDARY, and nothing here should be read as one: `node:vm`
// isolates globals, not the process, and code that gets to run inside a context
// can escape it. This is HARDENING — it raises the cost and removes the casual
// paths — plus bounded execution. The real reductions are elsewhere: assertions
// that do not need to run the region do not run it (test-ai-usage-entrypoint.js
// reads the payload field directly), and the region is reviewed like any other
// code in the diff.
//
// What the hardening does: `process`, `require`, `fetch`, `setTimeout` and
// Node's `console` are absent from the context; code generation is off, so
// `eval` and the `Function` constructor throw; EVERY entry into the region —
// building the exports and each individual call — runs under its own timeout;
// and only primitives cross the boundary in either direction. What it does NOT
// do: stop a determined escape from a vm context, or protect anything if this
// file's guarantees are read as a boundary and something else is relaxed on
// that basis.
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
    // host reference to a sandbox function back out, because calling one from the
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
    // code generation is allowed — and a sandbox object read from the host is the
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

module.exports = { regionOf, evaluateMarked };

// The self-test a library with no executable bit cannot run for itself;
// scripts/test-ai-usage-provider.js runs it before it evaluates anything.
module.exports.selfTest = function selfTest() {
    // Hardening, not a boundary: these prove the casual paths are closed, not
    // that escape is impossible.
    {
        const region = names => ["// BEGIN SELF TEST", names, "// END SELF TEST"].join("\n");
        const ok = evaluateMarked(
            region("function two() { return Math.max(1, JSON.parse('2')); }\n" +
                   "function shaped() { return { pct: 2, slots: [{ ok: true }] }; }"),
            "SELF TEST", ["two", "shaped"], "self-test");
        assert.equal(ok.two(), 2, "the intrinsics the decision code uses are there");
        assert.deepEqual(ok.shaped(), { pct: 2, slots: [{ ok: true }] },
            "and a value built in the sandbox comes back as host data, or every deepEqual in " +
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
        // call is its own bounded run, because a host reference to a sandbox
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
