#!/usr/bin/env node
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const { load } = require("../bin/lib/qml-library.js");
const file = path.join(__dirname, "..", "shell", "Core", "Lifetime.js");
const core = path.dirname(file);
const capabilitiesFile = path.join(core, "Capabilities.qml");
const pluginsFile = path.join(core, "Plugins.qml");
const hyprlandFile = path.join(core, "HyprlandState.qml");

function verify(library) {
    const errors = [];
    const lifetime = library.create(error => errors.push(error.message));
    assert.equal(lifetime.active, true);
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
    lifetime.register(() => assert.equal(lifetime.active, false, "teardown closes before callbacks run"));
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
    assert.equal(lifetime.active, false);
    assert.throws(() => lifetime.register(() => {}), /registration after teardown/);
}
verify(load(file));

// Evaluate the shipped context and compositor factory with a synthetic
// reader. No QML object, compositor or live session is created.
function verifyProvider(library, pluginsSource, capabilitiesSource, hyprlandSource) {
    const contextMatches = [...pluginsSource.matchAll(/Capabilities\.providersFor\((\{[^\n]+\})\);/g)];
    assert.equal(contextMatches.length, 1, "the instance context has one owner");
    const factoryMatches = [...capabilitiesSource.matchAll(/compositor: ctx => \{([\s\S]*?)\n        \},/g)];
    assert.equal(factoryMatches.length, 1, "one compositor provider factory is extracted");
    const keyFactoryMatches = [...hyprlandSource.matchAll(/function provider\(ctx\) \{([\s\S]*?)\n    \}/g)];
    assert.equal(keyFactoryMatches.length, 1, "one key provider factory is extracted");
    for (const [method, body] of [["observeInput", factoryMatches[0][1]], ["resolveKeys", keyFactoryMatches[0][1]]]) {
        const lifetime = library.create(error => { throw error; });
        const ctx = vm.runInNewContext("(" + contextMatches[0][1] + ")", {
            row: { lifetime }, id: "fixture", manifest: { capabilities: ["compositor"] },
            kind: "bar", hostKey: "bar:fixture", onScreen: null, locator: null
        });
        let pending = null;
        let observations = 0;
        const read = (input, done) => { observations++; pending = done; };
        const factory = vm.runInNewContext("ctx => {" + body + "\n}", {
            Dispatch: { PLUGIN_DISPATCHERS: [] }, Compositor: { observeInput: read }, root: { resolveKeys: read }
        });
        ctx.onDispose(() => {}); // The capability hold, owned by providersFor.
        const provider = factory(ctx);
        assert.equal(lifetime.count, 1, method + ": no duplicate lifetime callback");
        const replies = [];
        provider[method](null, value => replies.push(value));
        assert.equal(observations, 1, method + ": a live provider starts the observation");
        pending("live");
        assert.deepEqual(replies, ["live"], method + ": a live provider delivers the readback");
        provider[method](null, value => replies.push(value));
        assert.equal(observations, 2);
        lifetime.drain();
        assert.equal(ctx.active, false, "the context follows its lifetime at teardown");
        assert.equal(lifetime.count, 0);
        pending("stale");
        assert.deepEqual(replies, ["live"], method + ": a disposed provider drops an in-flight reply");
        provider[method](null, value => replies.push(value));
        assert.equal(observations, 2, method + ": a disposed provider starts no new observation");
        assert.deepEqual(replies, ["live"]);
    }
}
const pluginsSource = fs.readFileSync(pluginsFile, "utf8");
const capabilitiesSource = fs.readFileSync(capabilitiesFile, "utf8");
const hyprlandSource = fs.readFileSync(hyprlandFile, "utf8");
verifyProvider(load(file), pluginsSource, capabilitiesSource, hyprlandSource);

// Keep release execution intact but retain its entry. The same suite must
// reject retained entries after early release.
const source = fs.readFileSync(file, "utf8");
const unlink = "entry.pending.splice(entry.pending.indexOf(release), 1);";
assert.equal(source.split(unlink).length, 2);
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "lifetime-control-"));
try {
    const mutant = path.join(temp, "Lifetime.js");
    fs.writeFileSync(mutant, source.replace(unlink, ""));
    assert.throws(() => verify(load(mutant)), assert.AssertionError);
    const controls = [
        [file, "closed = true;", "closed = false;", "lifetime closes before release"],
        [pluginsFile, "return row.lifetime.active;", "return true;", "context reads the live lifetime"],
        [capabilitiesFile, "if (!ctx.active) return;", "if (false) return;", "disposed requests are dropped"],
        [capabilitiesFile, "if (ctx.active) done(value);", "if (true) done(value);", "disposed replies are dropped"],
        [hyprlandFile, "if (!ctx.active) return;", "if (false) return;", "disposed key requests are dropped"],
        [hyprlandFile, "if (ctx.active) done(value);", "if (true) done(value);", "disposed key replies are dropped"],
        [capabilitiesFile, "compositor: ctx => {", "compositor: ctx => { ctx.onDispose(() => {});", "duplicate compositor cleanup callback"],
        [hyprlandFile, "function provider(ctx) {", "function provider(ctx) { ctx.onDispose(() => {});", "duplicate key cleanup callback"]
    ];
    for (const [target, needle, replacement, name] of controls) {
        const original = fs.readFileSync(target, "utf8");
        assert.equal(original.split(needle).length - 1, 1, name + ": mutation match");
        const changed = original.replace(needle, replacement);
        assert.notEqual(changed, original, name + ": mutation changes bytes");
        const copy = path.join(temp, path.basename(target));
        fs.writeFileSync(copy, changed);
        assert.throws(() => {
            const library = target === file ? load(copy) : load(file);
            verify(library);
            verifyProvider(library, target === pluginsFile ? fs.readFileSync(copy, "utf8") : pluginsSource,
                target === capabilitiesFile ? fs.readFileSync(copy, "utf8") : capabilitiesSource,
                target === hyprlandFile ? fs.readFileSync(copy, "utf8") : hyprlandSource);
        }, assert.AssertionError, name + ": must fail an assertion");
        console.log("  ok    control: " + name);
    }
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log("test-lifetime: ok");
