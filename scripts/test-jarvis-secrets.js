#!/usr/bin/env node
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const { standins, ref } = require("./fixtures/jarvis/keys-world.js");
const tree = path.resolve(__dirname, "..");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const source = fs.readFileSync(path.join(backend, "Secrets.js"), "utf8");
const key = "test-key-must-stay-private";

function inside() {
    const api = require(path.join(backend, "Secrets.js"));
    const env = {};
    for (const name of ["PATH", "HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME",
        "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]) env[name] = process.env[name];
    const root = process.env.JARVIS_TEST_ROOT;
    const directory = path.join(env.XDG_STATE_HOME, "vgs/jarvis");
    const store = new api.Secrets(directory, { ...env, OPENAI_API_KEY: key, VGSH_RUNNER_PID: "123" });
    let cases = 0, controls = 0;
    const safe = value => assert.equal(String(value).includes(key), false, "no key in files, logs, argv, env or status");
    const calls = name => fs.existsSync(path.join(env.XDG_STATE_HOME, name))
        ? fs.readFileSync(path.join(env.XDG_STATE_HOME, name), "utf8") : "";
    const mode = value => fs.writeFileSync(path.join(env.XDG_STATE_HOME, "bus-mode"), value);
    function rejects(fn, expected) { assert.throws(fn, expected); cases++; }
    assert.deepEqual(store.references(), []);
    assert.equal(calls("secret-calls"), "");
    store.remember(ref);
    assert.deepEqual(store.references(), [ref]);
    assert.equal(fs.statSync(store.file).mode & 0o777, 0o600);
    for (const value of ["present", "locked", "absent", "failed", "junk"]) {
        mode(value);
        const row = store.rows()[0];
        assert.equal(row.value, ["failed", "junk"].includes(value) ? "unavailable" : value);
        safe(JSON.stringify(row));
        cases++;
    }
    assert.equal(calls("secret-calls"), "", "presence must not call secret-tool");
    const args = JSON.parse(calls("bus-calls").trim().split("\n")[0]);
    assert.deepEqual(args, ["--user", "--auto-start=no", "--allow-interactive-authorization=no",
        "--timeout=5", "--json=short", "call", "org.freedesktop.secrets", "/org/freedesktop/secrets",
        "org.freedesktop.Secret.Service", "SearchItems", "a{ss}", "4",
        "service", "vgs-jarvis", "provider", "fixture", "account", "test", "origin", "https://fixture.invalid"]);
    const lookedUp = store.lookup(ref);
    assert.equal(lookedUp.toString(), key);
    lookedUp.fill(0);
    const receipt = JSON.parse(calls("secret-calls").trim().split("\n")[0]);
    assert.deepEqual(receipt.argv, ["lookup", "service", "vgs-jarvis", "provider", "fixture",
        "account", "test", "origin", "https://fixture.invalid"]);
    assert.equal(receipt.env.OPENAI_API_KEY, undefined);
    assert.equal(receipt.env.VGSH_RUNNER_PID, undefined);
    safe(calls("secret-calls"));
    const external = { ...ref, account: "external", attributes: { application: "other-tool", id: "chosen-item" } };
    store.remember(external);
    assert.deepEqual(store.references()[1], external);
    assert.equal(store.lookup(external).toString(), key);
    rejects(() => store.addKey(ref), /store=terminal-required/);

    const referenceCases = [
        [{ ...ref, key }, /reference=shape/],
        [{ ...ref, provider: "" }, /reference=identity/],
        [{ ...ref, origin: "https://fixture.invalid/path" }, /reference=origin/],
        [{ ...ref, origin: "https://user:password@fixture.invalid" }, /reference=origin/],
        [{ ...ref, attributes: {} }, /reference=attributes/],
        [{ ...ref, attributes: { "--option": "x" } }, /reference=attributes/],
        [{ ...ref, attributes: { id: "x\nsecret" } }, /reference=attributes/]
    ];
    for (const [input, expected] of referenceCases) rejects(() => store.remember(input), expected);
    const clean = fs.readFileSync(store.file);
    for (const [data, expected] of [
        ["junk", /references=json/], [JSON.stringify([ref, ref]), /references=duplicate/],
        [JSON.stringify(Array(33).fill(ref)), /references=limit/],
        [" ".repeat(65537), /references=size/], [JSON.stringify([{ ...ref, key }]), /reference=shape/]
    ]) {
        fs.writeFileSync(store.file, data);
        rejects(() => store.references(), expected);
    }
    fs.writeFileSync(store.file, clean);
    fs.renameSync(store.file, store.file + ".saved");
    fs.symlinkSync(store.file + ".saved", store.file);
    rejects(() => store.references(), /references=read-failed/);
    fs.unlinkSync(store.file);
    fs.renameSync(store.file + ".saved", store.file);

    function tui(folder = path.dirname(backend), script = path.join(tree, "shell/plugins/vgs.jarvis/tui/add-key.sh")) {
        return cp.spawnSync("python3", [path.join(tree, "scripts/fixtures/jarvis/key-tui.py"),
            script, path.join(tree, "bin/lib/tui.sh"), folder], { env, encoding: "utf8", timeout: 15000 });
    }
    function goodTui(result) {
        assert.equal(result.error, undefined);
        assert.equal(result.status, 0, result.stdout + result.stderr);
        assert.match(result.stdout, /Password: /);
        assert.match(result.stdout, /jarvis-keys: stored=libsecret/);
        safe(result.stdout + result.stderr);
        assert.deepEqual(store.references().find(item => item.account === "test"), ref);
    }
    goodTui(tui());
    safe(calls("secret-calls"));
    const snapshot = fs.readFileSync(store.file);
    fs.writeFileSync(path.join(env.XDG_STATE_HOME, "store-fail"), "");
    const failed = tui();
    assert.equal(failed.status, 1);
    assert.match(failed.stdout, /jarvis-keys: secret-tool=failed/);
    safe(failed.stdout + failed.stderr);
    assert.deepEqual(fs.readFileSync(store.file), snapshot, "failed storage does not change references");
    fs.unlinkSync(path.join(env.XDG_STATE_HOME, "store-fail"));

    // Removing each stand-in must break its own behavioral assertion.
    for (const name of ["secret-tool", "busctl", "gum"]) {
        const file = path.join(env.PATH.split(":")[0], name);
        fs.renameSync(file, file + ".off");
        try {
            if (name === "busctl") {
                mode("present");
                assert.equal(store.rows()[0].value, "unavailable");
            } else assert.notEqual(tui().status, 0, name + " cannot fall back to the host");
        } finally { fs.renameSync(file + ".off", file); }
        cases++;
    }
    function mutate(name, needle, replacement, check) {
        assert.equal(source.split(needle).length - 1, 1, name + " mutation match");
        const file = path.join(root, name + ".js");
        fs.writeFileSync(file, source.replace(needle, replacement));
        assert.notEqual(fs.readFileSync(file, "utf8"), source);
        const copy = require(file);
        assert.throws(() => check(copy), assert.AssertionError, name + " must fail its assertion");
        controls++;
    }
    mutate("shape", "fail(\"reference=shape\");", "void 0;",
        copy => assert.throws(() => copy.reference({ ...ref, key }), /reference=shape/));
    mutate("identity", 'fail("reference=identity");', "void 0;",
        copy => assert.throws(() => copy.reference({ ...ref, account: "" }), /reference=identity/));
    mutate("origin", 'fail("reference=origin");\n    const attrs', 'void 0;\n    const attrs',
        copy => assert.throws(() => copy.reference({ ...ref, origin: "https://fixture.invalid/path" }), /reference=origin/));
    mutate("attributes", 'fail("reference=attributes");\n    return', 'void 0;\n    return',
        copy => assert.throws(() => copy.reference({ ...ref, attributes: { "--option": "x" } }), /reference=attributes/));
    mutate("attribute-count", 'fail("reference=attributes");\n    for', 'void 0;\n    for',
        copy => assert.throws(() => copy.reference({ ...ref, attributes: {} }), /reference=attributes/));
    for (const [name, needle, replacement, data, reason] of [
        ["size", "stat.size > MAX_BYTES", "false", " ".repeat(65537), /references=size/],
        ["count", "values.length > MAX_REFERENCES", "false", JSON.stringify(Array(33).fill(ref)), /references=limit/],
        ["duplicates", 'fail("references=duplicate");', "void 0;", JSON.stringify([ref, ref]), /references=duplicate/],
        ["remember-limit", 'if (refs.length > MAX_REFERENCES) fail("references=limit");',
            'if (false) fail("references=limit");', null, /references=limit/]
    ]) {
        mutate(name, needle, replacement, copy => {
            if (data !== null) {
                fs.writeFileSync(store.file, data);
                try { assert.throws(() => new copy.Secrets(directory, env).references(), reason); }
                finally { fs.writeFileSync(store.file, clean); }
            } else {
                fs.writeFileSync(store.file, JSON.stringify(Array.from({ length: 32 }, (_, index) =>
                    ({ ...ref, account: String(index) }))));
                try { assert.throws(() => new copy.Secrets(directory, env).remember(ref), reason); }
                finally { fs.writeFileSync(store.file, clean); }
            }
        });
    }
    mutate("env", "this.env = childEnvironment(env);", "this.env = env;",
        copy => safe(JSON.stringify(new copy.Secrets(directory, { ...env, OPENAI_API_KEY: key }).env)));
    mutate("presence", '"SearchItems", "a{ss}"', '"GetSecrets", "a{ss}"',
        copy => assert.equal(new copy.Secrets(directory, env).rows()[0].value, "present"));
    mutate("lookup", '["lookup", ...this.attributes(ref)]', '["search", ...this.attributes(ref)]',
        copy => assert.doesNotThrow(() => new copy.Secrets(directory, env).lookup(ref)));
    mutate("error-output", 'fail(command + "=" + cause);',
        'fail(result.stderr.toString());',
        copy => {
            fs.writeFileSync(path.join(env.XDG_STATE_HOME, "store-fail"), "");
            try { new copy.Secrets(directory, env).run("secret-tool", ["unknown"]); }
            catch (error) { safe(error.message); }
            finally { fs.unlinkSync(path.join(env.XDG_STATE_HOME, "store-fail")); }
        });
    // The actual TUI/CLI path, not a reimplementation, sees this mutation.
    const mutant = path.join(root, "tui-copy");
    fs.mkdirSync(path.join(mutant, "backend"), { recursive: true });
    fs.copyFileSync(path.join(backend, "keys.js"), path.join(mutant, "backend/keys.js"));
    const needle = 'output.fill(0);\n        this.remember(own);';
    assert.equal(source.split(needle).length - 1, 1);
    fs.writeFileSync(path.join(mutant, "backend/Secrets.js"),
        source.replace(needle, 'process.stdout.write(output);\n' + needle));
    assert.throws(() => goodTui(tui(mutant)), assert.AssertionError);
    controls++;
    fs.writeFileSync(path.join(mutant, "backend/Secrets.js"), source);
    const cliSource = fs.readFileSync(path.join(backend, "keys.js"), "utf8");
    const cliNeedle = "store.addKey(ref);";
    assert.equal(cliSource.split(cliNeedle).length - 1, 1);
    fs.writeFileSync(path.join(mutant, "backend/keys.js"), cliSource.replace(cliNeedle, "void ref;"));
    assert.throws(() => goodTui(tui(mutant)), assert.AssertionError, "CLI must call storage");
    controls++;
    fs.writeFileSync(path.join(mutant, "backend/keys.js"), cliSource);
    const scriptSource = fs.readFileSync(path.join(tree, "shell/plugins/vgs.jarvis/tui/add-key.sh"), "utf8");
    const scriptNeedle = 'add-key "$provider" "$account" "$origin"';
    assert.equal(scriptSource.split(scriptNeedle).length - 1, 1);
    const scriptCopy = path.join(root, "wrong-metadata.sh");
    fs.writeFileSync(scriptCopy, scriptSource.replace(scriptNeedle, 'add-key "$account" "$origin"'));
    assert.throws(() => goodTui(tui(path.dirname(backend), scriptCopy)), assert.AssertionError,
        "TUI must pass complete metadata, not a key");
    controls++;
    function walk(folder) {
        for (const item of fs.readdirSync(folder, { withFileTypes: true })) {
            const file = path.join(folder, item.name);
            if (item.isDirectory()) walk(file);
            else if (item.isFile()) safe(fs.readFileSync(file));
        }
    }
    // Fixture source and mutants contain the sentinel by design. The actual
    // state, account HOME, runtime and cache output directories must not.
    for (const folder of [env.XDG_STATE_HOME, env.HOME, env.XDG_RUNTIME_DIR]) walk(folder);
    console.log("test-jarvis-secrets: ok cases=" + cases + " controls=" + controls);
}

if (process.argv[2] === "--inside") inside();
else {
    fs.mkdirSync(path.join(tree, "tmp"), { recursive: true });
    const root = fs.mkdtempSync(path.join(tree, "tmp", "jk-"));
    try {
        standins(path.join(root, "standins"));
        const result = cp.spawnSync("/bin/bash", [path.join(tree, "scripts/lib/jarvis-env.sh"),
            path.join(root, "standins"), "--", "node", __filename, "--inside"], {
            env: { PATH: "/usr/bin:/bin", HOME: root }, encoding: "utf8", timeout: 60000 });
        process.stdout.write(result.stdout || "");
        process.stderr.write(result.stderr || "");
        if (result.error) throw result.error;
        process.exitCode = result.status ?? 1;
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
