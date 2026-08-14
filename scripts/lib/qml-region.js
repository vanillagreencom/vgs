// Evaluating the decision region a QML file marks off, for the tests that need
// to run it. Separate from scripts/lib/qml-source.js on purpose: reading source
// is safe, running it is the part with a threat model.

"use strict";

const assert = require("node:assert/strict");
const vm = require("node:vm");

// Evaluate the decision region a QML file marks off.
//
// NOT A SECURITY BOUNDARY, and nothing here should be read as one: `node:vm`
// isolates globals, not the process, and code that gets to run inside a context
// can escape it. This is HARDENING — it raises the cost and removes the casual
// paths — plus a timeout so a planted loop fails instead of hanging CI. The real
// reductions are elsewhere: assertions that do not need to run the region do not
// run it (scripts/test-ai-usage-entrypoint.js reads the payload field directly),
// and the region itself is reviewed like any other code in the diff.
//
// What the hardening does: `process`, `require`, `fetch`, `setTimeout` and
// Node's `console` are absent from the context, and code generation is off, so
// `eval` and the `Function` constructor throw. What it does NOT do: stop a
// determined escape from a vm context, or protect anything if this file's own
// guarantees are read as a boundary and something else is relaxed on that basis.
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

function evaluateMarked(source, marker, names, label) {
    const region = regionOf(source, marker, label);
    // console is Node's, not an intrinsic: shadowed so the region cannot reach it.
    // codeGeneration off makes eval and the Function constructor throw, so the
    // region cannot build new code at runtime.
    const context = vm.createContext({ console: undefined },
        { codeGeneration: { strings: false, wasm: false } });
    const factory = `(function () {\n${region}\nreturn { ${names.join(", ")} };\n})()`;
    const exported = vm.runInContext(factory, context,
        { filename: `${label}:${marker}`, timeout: 5000 });

    // Values built inside the sandbox carry ITS intrinsics, so a plain object
    // from there is not deepStrictEqual to one written here. Each function hands
    // its result back as host data; the realm is the sandbox's business.
    const out = {};
    for (const name of names) {
        const value = exported[name];
        out[name] = typeof value === "function"
            ? (...args) => hostValue(value(...args))
            : hostValue(value);
    }
    return out;
}

function hostValue(value) {
    if (value === null || typeof value !== "object")
        return value;
    if (Array.isArray(value)) {
        // Built here: the sandbox's Array.prototype.map returns ITS array.
        const list = [];
        for (let i = 0; i < value.length; i++)
            list.push(hostValue(value[i]));
        return list;
    }
    const out = {};
    for (const key of Object.keys(value))
        out[key] = hostValue(value[key]);
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
        assert.throws(() => evaluateMarked(region("while (true) {}\nfunction f() {}"),
            "SELF TEST", ["f"], "self-test"), /timed out/,
            "and a planted infinite loop must time out rather than hang CI");
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
