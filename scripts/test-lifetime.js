#!/usr/bin/env node
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("./qml-library.js");
const file = path.join(__dirname, "..", "shell", "Core", "Lifetime.js");

function verify(library) {
    const errors = [];
    const lifetime = library.create(error => errors.push(error.message));
    let released = 0;
    for (let i = 0; i < 1000; i++) {
        const release = lifetime.register(() => released++);
        assert.equal(lifetime.count, 1);
        release();
        release();
        assert.equal(lifetime.count, 0);
    }
    assert.equal(released, 1000);
    const order = [];
    lifetime.register(() => order.push("first"));
    const early = lifetime.register(() => order.push("early"));
    lifetime.register(() => { order.push("throw"); throw new Error("cleanup failed"); });
    lifetime.register(() => order.push("last"));
    early();
    lifetime.drain();
    early();
    lifetime.drain();
    assert.deepEqual(order, ["early", "last", "throw", "first"]);
    assert.deepEqual(errors, ["cleanup failed"]);
    assert.equal(lifetime.count, 0);
    assert.throws(() => lifetime.register(() => {}), /registration after teardown/);
}
verify(load(file));

// Keep release execution intact but retain its entry. The same suite must
// reject the defect that repeated early release previously left behind.
const source = fs.readFileSync(file, "utf8");
const unlink = "entry.pending.splice(entry.pending.indexOf(release), 1);";
assert.equal(source.split(unlink).length, 2);
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "lifetime-control-"));
try {
    const mutant = path.join(temp, "Lifetime.js");
    fs.writeFileSync(mutant, source.replace(unlink, ""));
    assert.throws(() => verify(load(mutant)), assert.AssertionError);
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log("test-lifetime: ok");
