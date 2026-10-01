#!/usr/bin/env node
"use strict";
const { assert, fs, path, cp, tree, environment, world, mutant } = require("./fixtures/jarvis/accounts-world.js");
const plugin = path.join(tree, "shell/plugins/vgs.jarvis");
const privateValue = "fixture-secret-private";

world(async () => {
    const env = environment();
    const directory = path.join(env.XDG_STATE_HOME, "vgs/jarvis");
    const { Accounts } = require(path.join(plugin, "backend/Accounts.js"));
    const { Secrets, ownReference } = require(path.join(plugin, "backend/Secrets.js"));
    const { PROVIDERS, keyPresence, helperFailure, feedDiagnostic, probeFailure } = require(path.join(plugin, "AccountProviders.js"));
    const mode = (name, value) => fs.writeFileSync(path.join(env.XDG_STATE_HOME, name + "-mode"), value);
    const calls = name => fs.existsSync(path.join(env.XDG_STATE_HOME, name))
        ? fs.readFileSync(path.join(env.XDG_STATE_HOME, name), "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : [];
    const safe = value => assert.equal(JSON.stringify(value).includes(privateValue), false, "no secret in metadata, status or diagnosis");
    const markerReads = [];
    const markerChecks = [];
    let markerOrder = null;
    const originalStat = fs.lstatSync;
    fs.lstatSync = function (file, ...args) {
        if (typeof file === "string" && [".credentials.json", "auth.json"].includes(path.basename(file))) {
            markerChecks.push(file);
            if (markerOrder !== null) {
                const count = calls("cli-calls").length;
                assert.ok(count > markerOrder.value, "each marker check follows its candidate's vendor account command");
                markerOrder.value = count;
            }
        }
        return originalStat.call(fs, file, ...args);
    };
    for (const method of ["readFileSync", "openSync", "createReadStream"]) {
        const original = fs[method];
        fs[method] = function (file, ...args) {
            if (typeof file === "string" && [".credentials.json", "auth.json"].includes(path.basename(file)))
                markerReads.push([method, file]);
            return original.call(fs, file, ...args);
        };
    }
    const seed = (root, name, marker) => {
        const folder = path.join(root, name);
        fs.mkdirSync(folder, { recursive: true });
        if (marker) fs.writeFileSync(path.join(folder, marker), privateValue, { mode: 0o000 });
        return folder;
    };
    const defaultClaude = seed(env.HOME, ".claude", ".credentials.json");
    const nestedClaude = seed(env.XDG_CONFIG_HOME, "accounts/.claude-team", ".credentials.json");
    const unicodeClaude = seed(env.XDG_CONFIG_HOME, "unicode/.claude-équipe", ".credentials.json");
    const nestedCodex = seed(env.XDG_DATA_HOME, "work/.codex-business", "auth.json");
    const hand = seed(env.HOME, "hand-added", ".credentials.json");
    const explicit = seed(env.HOME, "explicit", "auth.json");
    seed(env.HOME, "deep/inner/.claude-too-deep", ".credentials.json");
    const linked = seed(process.env.JARVIS_TEST_ROOT, "link-target", ".credentials.json");
    fs.symlinkSync(linked, path.join(env.HOME, ".claude-link"));
    fs.symlinkSync(linked, path.join(env.XDG_DATA_HOME, "link-parent"));
    const store = new Accounts(directory, { ...env, CODEX_HOME: explicit,
        OPENAI_API_KEY: privateValue, VGSH_RUNNER_PID: "123" });
    store.add({ provider: "claude", directory: hand, label: "hand" });
    assert.equal(fs.statSync(store.file).mode & 0o777, 0o600);
    let cases = 0, controls = 0;
    const diagnosticCases = [
        ["jarvis-accounts: discovery=entry-limit\n", "jarvis-accounts: discovery=entry-limit"],
        ["jarvis-accounts: added=json\n", "jarvis-accounts: added=json"],
        ["jarvis-keys: busctl=missing\n", "jarvis-keys: busctl=missing"],
        ["jarvis-accounts: discovery=" + privateValue, ""],
        ["jarvis-accounts: added=json\n" + privateValue, ""],
        ["node: " + privateValue, ""],
        ["constructor: name=object", ""],
        ["jarvis-accounts: constructor=object", ""]
    ];
    for (const [input, expected] of diagnosticCases) {
        assert.equal(helperFailure(input), expected);
        cases++;
    }
    const collected = text => feedDiagnostic({ kind: "collected", text: "" }, text);
    const completionCases = [
        [{ kind: "starting" }, "", "jarvis-accounts: process=start-failed"],
        [{ kind: "crashed" }, privateValue, "jarvis-accounts: process=crashed"],
        [{ kind: "exited", code: 0 }, privateValue, "jarvis-accounts: output=invalid"],
        [{ kind: "exited", code: 1 }, "jarvis-accounts: added=json\n", "jarvis-accounts: added=json"],
        [{ kind: "exited", code: 1 }, privateValue, "jarvis-accounts: process=failed"]
    ];
    for (const [completion, text, expected] of completionCases) {
        const value = probeFailure(completion, collected(text));
        assert.equal(value, expected);
        safe(value);
        cases++;
    }
    let bounded = collected("x".repeat(256));
    assert.equal(bounded.kind, "collected");
    bounded = feedDiagnostic(bounded, "x");
    assert.deepEqual(bounded, { kind: "oversize" });
    assert.equal(probeFailure({ kind: "exited", code: 1 }, bounded), "jarvis-accounts: diagnostic=oversize");
    await mutant("AccountProviders.js", "safe-diagnostic-key",
        'if (!Array.isArray(codes) || codes.indexOf(match[3]) === -1) return "";',
        'if (false) return "";', folder => {
            const api = require(path.join(folder, "AccountProviders.js"));
            assert.equal(api.helperFailure("jarvis-accounts: discovery=" + privateValue), "");
        });
    controls++;
    await mutant("AccountProviders.js", "bounded-diagnostic", "if (text.length > MAX_DIAGNOSTIC_CHARS)",
        "if (false)", folder => {
            const api = require(path.join(folder, "AccountProviders.js"));
            assert.deepEqual(api.feedDiagnostic({ kind: "collected", text: "" }, "x".repeat(257)), { kind: "oversize" });
        });
    controls++;
    await mutant("AccountProviders.js", "preserved-diagnostic-cause",
        'return helperFailure(diagnostic.text) || "jarvis-accounts: process=failed";',
        'return "jarvis-accounts: process=failed";', folder => {
            const api = require(path.join(folder, "AccountProviders.js"));
            assert.equal(api.probeFailure({ kind: "exited", code: 1 }, collected("jarvis-accounts: added=json\n")),
                "jarvis-accounts: added=json");
        });
    controls++;

    function discovery(judge) {
        const before = markerReads.length;
        markerOrder = { value: calls("cli-calls").length };
        let rows;
        try { rows = judge.discover(); } finally { markerOrder = null; }
        assert.equal(markerReads.length, before, "no marker content API is called, even if mode 000 can be bypassed");
        assert.ok(rows.some(item => item.source.directory === nestedClaude), "nested Claude");
        assert.ok(rows.some(item => item.source.directory === unicodeClaude && item.label === "équipe"), "Unicode directory");
        assert.ok(rows.some(item => item.source.directory === nestedCodex), "nested Codex");
        assert.ok(rows.some(item => item.source.directory === hand && item.label === "hand"), "manual directory");
        assert.ok(rows.some(item => item.source.directory === explicit), "explicit directory");
        assert.ok(rows.some(item => item.source.directory === defaultClaude), "mode 000 marker");
        assert.equal(rows.find(item => item.source.directory === defaultClaude).marker, "present");
        assert.equal(rows.some(item => item.source.directory?.includes("too-deep")), false, "depth bound");
        assert.equal(rows.some(item => item.source.directory?.includes("link")), false, "links excluded");
        assert.equal(rows.find(item => item.source.directory === nestedClaude).state.kind, "signed-in");
        assert.equal(rows.find(item => item.source.directory === nestedClaude).identity.kind, "mismatch");
        assert.ok(rows.some(item => item.source.kind === "variable" && item.provider === "openai"));
        assert.ok(rows.some(item => item.source.kind === "local" && item.provider === "ollama"));
        assert.equal(rows.some(item => item.state.kind === "verified"), false, "discovery is never verification");
        safe(judge.status());
        return rows;
    }
    let rows = discovery(store);
    for (const call of [...calls("cli-calls"), ...calls("port-calls")]) {
        assert.equal(call.env.OPENAI_API_KEY, undefined);
        assert.equal(call.env.VGSH_RUNNER_PID, undefined);
        assert.ok(["auth,status", "login,status", "-H,-ltn"].includes(call.args.join(",")));
        safe(call);
    }
    assert.equal(calls("secret-calls").length, 0);
    cases++;

    for (const [name, value, expected] of [
        ["claude", "found", "found"], ["claude", "failed", "unavailable"], ["claude", "junk", "unavailable"],
        ["codex", "api", "signed-in"], ["codex", "found", "found"], ["codex", "failed", "unavailable"], ["codex", "junk", "unavailable"]
    ]) {
        mode(name, value);
        const item = store.discover().find(row => row.provider === name && row.source.directory);
        assert.equal(item.state.kind, expected);
        safe(store.status());
        mode(name, "signed-in");
        cases++;
    }

    const references = new Secrets(directory, env);
    for (const [selected, reason, needle, replacement] of [
        ["too-many", /items=limit-or-duplicate/, "paths.length > MAX_REFERENCES", "false"],
        ["duplicate", /items=limit-or-duplicate/, "new Set(paths).size !== paths.length", "false"],
        ["property-type", /items=reply/, "reply.type !== type", "false"],
        ["property-extra", /items=reply/, "reply.data.length !== 1", "false"],
        ["property-object", /items=reply/, "reply.type !== type || !Array.isArray(reply.data)", "reply.type !== type || false"],
        ["empty-label", /items=label/, 'fail("items=label");', "void 0;"]
    ]) {
        mode("bus", selected);
        const assertion = Store => assert.throws(() => new Store(directory, env).items(), reason);
        assertion(Secrets);
        await mutant("backend/Secrets.js", "items-" + selected, needle, replacement, folder =>
            assertion(require(path.join(folder, "backend/Secrets.js")).Secrets));
        controls++;
        cases++;
    }
    mode("bus", "unicode-label");
    assert.ok(references.items().some(item => item.label === "Other tool API clé"));
    mode("bus", "present");
    for (const value of ["present", "locked", "absent", "failed", "junk"]) {
        mode("bus", value);
        const ref = { provider: "openai", account: "other", origin: "https://api.openai.com",
            attributes: { application: "other-tool", id: "api-key" } };
        references.remember(ref);
        const item = store.discover().find(row => row.source.kind === "keyring");
        assert.equal(item.state.kind, value === "present" ? "found" : value === "locked" ? "locked" : "unavailable");
        assert.equal(store.status().brains.some(row => row.value === item.id), value === "present");
        safe(store.status());
        cases++;
    }
    mode("bus", "present");
    const items = store.keyItems();
    assert.deepEqual(items.map(item => item.label), ["Other tool API key"]);
    store.remember(items[0].path, "anthropic", "chosen label");
    assert.deepEqual(references.references()[1].attributes, { application: "other-tool", id: "api-key" });
    const unicodeRef = { provider: "custom-tool", account: "clé", origin: "https://custom.invalid",
        attributes: { application: "other-tool", user: "développeur" } };
    references.remember(unicodeRef);
    assert.deepEqual(references.references()[2], unicodeRef);
    const ownedAlias = ownReference("anthropic", "Claude Code", "https://api.anthropic.com");
    references.remember(ownedAlias);
    assert.equal(store.discover().find(item => item.source.reference?.account === "Claude Code").state.kind, "found");
    const stableReference = Judge => {
        const original = references.references().find(ref => ref.account === "other");
        const before = new Judge(directory, env).discover().find(item => item.source.reference?.account === "other").id;
        try {
            references.remember({ ...original, attributes: Object.fromEntries(Object.entries(original.attributes).reverse()) });
            const after = new Judge(directory, env).discover().find(item => item.source.reference?.account === "other").id;
            assert.equal(after, before, "dictionary order is not account identity");
        } finally { references.remember(original); }
    };
    stableReference(Accounts);
    await mutant("backend/Accounts.js", "stable-reference-id",
        'Object.fromEntries(Object.entries(value).sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0))',
        "value", folder => stableReference(require(path.join(folder, "backend/Accounts.js")).Accounts));
    controls++;
    cases++;
    const unknown = store.discover().find(item => item.provider === "custom-tool");
    assert.deepEqual(unknown.state, { kind: "unavailable", reason: "provider-unsupported" });
    assert.equal(store.status().brains.some(choice => choice.value === unknown.id), false);
    let unknownRequests = 0;
    await assert.rejects(() => store.verify(unknown.id, "user", async () => {
        unknownRequests++; return { kind: "inference", text: "OK" };
    }), /verify=provider-unsupported/);
    assert.equal(unknownRequests, 0);
    await mutant("backend/Accounts.js", "unknown-provider-verify",
        'fail("verify=provider-unsupported");',
        'void 0;', async folder => {
            const judge = new (require(path.join(folder, "backend/Accounts.js")).Accounts)(directory, env);
            const item = judge.discover().find(row => row.provider === "custom-tool");
            await assert.rejects(() => judge.verify(item.id, "user", async () => ({ kind: "inference", text: "OK" })),
                /verify=provider-unsupported/);
        });
    controls++;
    cases++;
    // The daemon resolves a saved choice without discovery's vendor commands.
    const resolution = Judge => {
        const judge = new Judge(directory, env);
        const found = store.discover();
        const before = [calls("cli-calls").length, calls("port-calls").length, calls("secret-calls").length];
        const keyring = found.find(item => item.source.reference?.account === "chosen label");
        assert.deepEqual(judge.resolve(keyring.id), { id: keyring.id, provider: "anthropic", label: "chosen label",
            source: keyring.source, model: "claude-haiku-4-5" });
        const local = store.account(PROVIDERS.find(row => row.id === "ollama"), "local", { kind: "found" },
            { kind: "local", origin: "http://127.0.0.1:11434" });
        assert.deepEqual(judge.resolve(local.id), { id: local.id, provider: "ollama", label: "local",
            source: local.source, model: "" });
        for (const other of [found.find(item => item.source.kind === "cli").id, unknown.id, "", "keyring:0"]) {
            let value;
            assert.doesNotThrow(() => { value = judge.resolve(other); }, "resolution judges every saved reference");
            assert.equal(value, null, "a subscription, unsupported or unknown id selects nothing");
        }
        assert.deepEqual([calls("cli-calls").length, calls("port-calls").length, calls("secret-calls").length], before,
            "resolution runs no vendor command, port read or key lookup");
    };
    resolution(Accounts);
    await mutant("backend/Accounts.js", "resolve-unsupported", 'if (row.kind !== "key" && row.kind !== "local") continue;', "",
        folder => resolution(require(path.join(folder, "backend/Accounts.js")).Accounts));
    controls++;
    cases++;
    safe(fs.readFileSync(references.file, "utf8"));
    assert.throws(() => store.remember("/org/freedesktop/secrets/collection/test/cli", "openai", "login"), /reference=item-unavailable/);
    assert.throws(() => store.remember(items[0].path, "claude", "login"), /reference=provider/);
    assert.equal(calls("secret-calls").length, 0, "picker never looks up a secret");
    for (const call of calls("bus-calls")) {
        assert.equal(call.args.some(arg => /GetSecret|Unlock|search/.test(arg)), false);
        safe(call);
    }
    cases++;

    rows = store.discover();
    const chosen = rows.find(row => row.source.directory === nestedClaude).id;
    let inferenceCalls = 0;
    const request = async account => { inferenceCalls++; assert.equal(account.id, chosen); return { kind: "inference", text: "OK" }; };
    assert.equal(inferenceCalls, 0);
    await assert.rejects(() => store.verify(chosen, "automatic", request), /explicit-user-required/);
    assert.equal(inferenceCalls, 0);
    assert.deepEqual(await store.verify(chosen, "user"), { kind: "unavailable", reason: "subscription-handoff-unavailable" });
    assert.equal(inferenceCalls, 0);
    assert.deepEqual(await store.verify(chosen, "user", request), { kind: "verified" });
    assert.equal(inferenceCalls, 1);
    assert.equal(store.accounts.find(row => row.id === chosen).state.kind, "verified");
    store.discover();
    assert.equal(store.accounts.find(row => row.id === chosen).state.kind, "signed-in", "no cached verification");
    for (const response of [{ kind: "models", text: "OK" }, { kind: "inference", text: "" }, { kind: "signed-in", text: "OK" }])
        assert.equal((await store.verify(chosen, "user", async () => response)).kind, "unavailable");
    let finish;
    const held = store.verify(chosen, "user", () => new Promise(resolve => { finish = resolve; }));
    await assert.rejects(() => store.verify(chosen, "user", request), /verify=busy/);
    store.discover();
    finish({ kind: "inference", text: "OK" });
    assert.deepEqual(await held, { kind: "superseded" });
    assert.equal(store.accounts.find(row => row.id === chosen).state.kind, "signed-in");
    mode("bus", "locked");
    const lockedId = store.discover().find(row => row.source.kind === "keyring").id;
    await assert.rejects(() => store.verify(lockedId, "user", request), /verify=keyring-locked/);
    mode("bus", "present");
    cases++;

    const metadata = fs.readFileSync(store.file);
    const additions = Array.from({ length: 33 }, (_, index) => ({
        provider: "claude", directory: seed(process.env.JARVIS_TEST_ROOT, "added-" + index), label: String(index)
    }));
    for (const [data, expected, needle, replacement] of [
        ["[]".padEnd(65537, " "), /added=size/, "stat.size > MAX_BYTES", "false"],
        [JSON.stringify(additions), /added=limit/, "values.length > MAX_ROWS", "false"],
        [JSON.stringify([additions[0], additions[0]]), /added=duplicate/, 'fail("added=duplicate");', "void 0;"],
        [JSON.stringify([{ ...additions[0], token: privateValue }]), /added=shape/,
            'Object.keys(value).sort().join(",") !== "directory,label,provider"', "false"]
    ]) {
        fs.writeFileSync(store.file, data);
        const assertion = Judge => assert.throws(() => new Judge(directory, env).added(), expected);
        assertion(Accounts);
        await mutant("backend/Accounts.js", "metadata-" + expected.source, needle, replacement, folder =>
            assertion(require(path.join(folder, "backend/Accounts.js")).Accounts));
        fs.writeFileSync(store.file, metadata);
        controls++;
        cases++;
    }
    fs.writeFileSync(store.file, JSON.stringify(additions.slice(0, 32)));
    const addLimit = Judge => assert.throws(() => new Judge(directory, env).add(additions[32]), /added=limit/);
    addLimit(Accounts);
    await mutant("backend/Accounts.js", "added-write-limit", "entries.length > MAX_ROWS", "false", folder =>
        addLimit(require(path.join(folder, "backend/Accounts.js")).Accounts));
    fs.writeFileSync(store.file, metadata);
    controls++;
    for (const [data, expected] of [["junk", /added=json/], ["[]".padEnd(65537, " "), /added=size/],
        [JSON.stringify(Array(33).fill({ provider: "claude", directory: hand, label: "hand" })), /added=limit/],
        [JSON.stringify([{ provider: "claude", directory: hand, label: "hand", token: privateValue }]), /added=shape/]]) {
        fs.writeFileSync(store.file, data);
        assert.throws(() => store.discover(), expected);
        fs.writeFileSync(store.file, metadata);
        cases++;
    }
    assert.throws(() => store.add({ provider: "claude", directory: path.join(env.HOME, ".claude-link"), label: "link" }), /directory=link/);
    assert.throws(() => new Accounts(directory, { ...env, CLAUDE_CONFIG_DIR: path.join(env.HOME, ".claude-link") }).discover(), /directory=link/);
    fs.renameSync(store.file, store.file + ".saved");
    fs.symlinkSync(store.file + ".saved", store.file);
    assert.throws(() => store.discover(), /added=read-failed/);
    fs.unlinkSync(store.file);
    fs.renameSync(store.file + ".saved", store.file);
    cases++;

    const crowd = seed(env.HOME, "crowd");
    for (let i = 0; i < 200; i++) fs.writeFileSync(path.join(crowd, String(i)), "");
    const entryBound = Judge => assert.throws(() => new Judge(directory, env).discover(), /entry-limit/);
    entryBound(Accounts);
    await mutant("backend/Accounts.js", "entry-bound", "if (visited.size > MAX_ENTRIES)", "if (false)", folder =>
        entryBound(require(path.join(folder, "backend/Accounts.js")).Accounts));
    controls++;
    fs.rmSync(crowd, { recursive: true });
    const many = seed(env.HOME, "many");
    for (let i = 0; i < 33; i++) seed(many, ".claude-" + i);
    const accountBound = Judge => {
        const before = calls("cli-calls").length;
        assert.throws(() => new Judge(directory, env).discover(), /account-limit/);
        assert.equal(calls("cli-calls").length, before, "candidate overflow must fail before login probes");
    };
    accountBound(Accounts);
    await mutant("backend/Accounts.js", "account-bound", "if (candidates.length > MAX_ROWS)", "if (false)", folder =>
        accountBound(require(path.join(folder, "backend/Accounts.js")).Accounts));
    controls++;
    fs.rmSync(many, { recursive: true });
    const late = path.join(env.HOME, "late-account");
    const lateLink = Judge => {
        mode("claude", "late-link");
        const before = markerChecks.length;
        try {
            const judge = new Judge(directory, { ...env, CLAUDE_CONFIG_DIR: late });
            const item = judge.discover().find(row => row.source.directory === late);
            assert.equal(item.marker, "absent", "an absent directory has no held marker parent");
            assert.equal(markerChecks.slice(before).some(file => file.startsWith(late + "/")), false,
                "a new link cannot become a marker's parent");
        } finally {
            mode("claude", "signed-in");
            if (fs.existsSync(late)) fs.unlinkSync(late);
        }
    };
    lateLink(Accounts);
    await mutant("backend/Accounts.js", "late-marker-link", 'if (opened.kind === "directory") {\n                const markerPath',
        'if (opened.kind !== "directory") fs.lstatSync(path.join(candidate.directory, row.marker));\n            if (opened.kind === "directory") {\n                const markerPath',
        folder => lateLink(require(path.join(folder, "backend/Accounts.js")).Accounts));
    controls++;
    cases++;
    const boundRoot = path.join(process.env.JARVIS_TEST_ROOT, "exact-bound");
    const boundEnv = { ...env, HOME: path.join(boundRoot, "home"), XDG_CONFIG_HOME: path.join(boundRoot, "config"),
        XDG_DATA_HOME: path.join(boundRoot, "data") };
    for (const folder of [boundEnv.HOME, boundEnv.XDG_CONFIG_HOME, boundEnv.XDG_DATA_HOME]) fs.mkdirSync(folder, { recursive: true });
    for (let i = 0; i < 200; i++) fs.writeFileSync(path.join(boundEnv.HOME, String(i)), "");
    assert.doesNotThrow(() => new Accounts(path.join(boundRoot, "state"), boundEnv).discover(), "exactly 200 entries are permitted");
    const referenceBytes = fs.readFileSync(references.file);
    fs.writeFileSync(references.file, JSON.stringify(Array.from({ length: 32 }, (_, index) => ({
        provider: "openai", account: String(index), origin: "https://api.openai.com", attributes: { id: String(index) }
    }))));
    const finalBound = Judge => assert.throws(() => new Judge(directory, env).discover(), /account-limit/);
    finalBound(Accounts);
    await mutant("backend/Accounts.js", "status-bound", "if (result.length > MAX_ROWS)", "if (false)", folder =>
        finalBound(require(path.join(folder, "backend/Accounts.js")).Accounts));
    controls++;
    fs.writeFileSync(references.file, referenceBytes);

    for (const [name, needle, replacement, check] of [
        ["marker-open", "const stat = fs.lstatSync(markerPath);", "const stat = (fs.readFileSync(markerPath), fs.lstatSync(markerPath));",
            Judge => discovery(new Judge(directory, { ...env, CODEX_HOME: explicit, OPENAI_API_KEY: privateValue }))],
        ["marker-first", "const result = this.run(row.command[0], row.command.slice(1), { [row.variable]: candidate.directory });",
            "fs.lstatSync(path.join(candidate.directory, row.marker));\n        const result = this.run(row.command[0], row.command.slice(1), { [row.variable]: candidate.directory });",
            Judge => discovery(new Judge(directory, { ...env, CODEX_HOME: explicit, OPENAI_API_KEY: privateValue }))],
        ["depth", "else if (depth < 2)", "else if (depth < 3)",
            Judge => discovery(new Judge(directory, { ...env, CODEX_HOME: explicit, OPENAI_API_KEY: privateValue }))],
        ["manual", "for (const item of this.added())", "for (const item of [])",
            Judge => discovery(new Judge(directory, { ...env, CODEX_HOME: explicit, OPENAI_API_KEY: privateValue }))],
        ["no-follow", 'if (stat.isSymbolicLink()) fail("directory=link");', 'if (stat.isSymbolicLink()) return { kind: "absent" };',
            Judge => assert.throws(() => new Judge(directory, { ...env, CLAUDE_CONFIG_DIR: path.join(env.HOME, ".claude-link") }).discover(), /directory=link/)],
        ["explicit-user", 'if (initiation !== "user")', "if (false)",
            async Judge => { const judge = new Judge(directory, env); const id = judge.discover()[0].id;
                await assert.rejects(() => judge.verify(id, "automatic", async () => ({ kind: "inference", text: "OK" })), /explicit-user-required/); }],
        ["inference-proof", 'answer.kind !== "inference"', "false",
            async Judge => { const judge = new Judge(directory, env); const id = judge.discover()[0].id;
                assert.equal((await judge.verify(id, "user", async () => ({ kind: "models", text: "OK" }))).kind, "unavailable"); }],
        ["stale-verify", "this.epoch !== epoch", "false",
            async Judge => { const judge = new Judge(directory, env); const id = judge.discover()[0].id; let done;
                const pending = judge.verify(id, "user", () => new Promise(resolve => { done = resolve; }));
                judge.discover(); done({ kind: "inference", text: "OK" }); assert.deepEqual(await pending, { kind: "superseded" }); }],
        ["vendor-token", "return /(claude[ -]?code|codex|copilot|oauth|refresh[ _-]?token|access[ _-]?token)/.test(text);", "return false;",
            Judge => assert.deepEqual(new Judge(directory, env).keyItems().map(item => item.label), ["Other tool API key"])],
        ["login-is-not-inference", 'return { kind: "signed-in", email, plan };', 'return { kind: "verified", email, plan };',
            Judge => discovery(new Judge(directory, { ...env, CODEX_HOME: explicit, OPENAI_API_KEY: privateValue }))],
        ["child-environment", "this.env = childEnvironment(env);", "this.env = env;",
            Judge => { const before = calls("cli-calls").length;
                new Judge(directory, { ...env, OPENAI_API_KEY: privateValue }).discover();
                for (const call of calls("cli-calls").slice(before)) assert.equal(call.env.OPENAI_API_KEY, undefined); }]
    ]) {
        await mutant("backend/Accounts.js", name, needle, replacement, folder => check(require(path.join(folder, "backend/Accounts.js")).Accounts));
        controls++;
    }
    await mutant("backend/Secrets.js", "metadata-only", '"get-property",', '"call",', folder =>
        assert.doesNotThrow(() => new (require(path.join(folder, "backend/Secrets.js")).Secrets)(directory, env).items()));
    controls++;

    // A missing stand-in cannot reach a host executable.
    for (const [command, assertion] of [
        ["claude", judge => {
            assert.equal(judge.discover().find(row => row.provider === "claude").state.kind, "unavailable");
            assert.throws(() => discovery(judge), assert.AssertionError);
        }],
        ["ss", judge => {
            assert.equal(judge.discover().find(row => row.provider === "ollama").state.kind, "unavailable");
            assert.throws(() => discovery(judge), assert.AssertionError);
        }],
        ["busctl", judge => {
            assert.throws(() => judge.keyItems(), /busctl=missing/);
            assert.throws(() => assert.doesNotThrow(() => judge.keyItems()), assert.AssertionError);
        }]
    ]) {
        const file = path.join(process.env.JARVIS_TEST_ROOT, "standins", command);
        fs.renameSync(file, file + ".removed");
        try { assertion(new Accounts(directory, env)); }
        finally { fs.renameSync(file + ".removed", file); }
        cases++;
    }
    mode("ports", "junk");
    assert.throws(() => store.discover(), /ports=reply/);
    mode("ports", "present");

    function cli(folder, args) {
        return cp.spawnSync("node", [path.join(folder, "backend/accounts.js"), ...args], {
            env, encoding: "utf8", timeout: 15000 });
    }
    const goodCli = folder => {
        const result = cli(folder, ["list"]);
        assert.equal(result.status, 0, result.stdout + result.stderr);
        assert.ok(JSON.parse(result.stdout).some(item => item.source.directory === hand));
        safe(result.stdout + result.stderr);
    };
    goodCli(plugin);
    const normalizedError = folder => {
        const result = cli(folder, ["presence", privateValue]);
        assert.equal(result.status, 1);
        assert.equal(result.stderr, "jarvis-accounts: operation=failed\n");
        safe(result.stdout + result.stderr);
    };
    normalizedError(plugin);
    await mutant("backend/accounts.js", "safe-cli-error",
        'const reason = helperFailure(error.message) || "jarvis-accounts: operation=failed";',
        "const reason = error.message;", normalizedError);
    controls++;
    const refused = cli(plugin, ["verify", chosen, "user"]);
    assert.equal(refused.status, 69);
    assert.deepEqual(JSON.parse(refused.stdout), { kind: "unavailable", reason: "subscription-handoff-unavailable" });
    const automatic = cli(plugin, ["verify", chosen]);
    assert.equal(automatic.status, 1);
    await mutant("backend/accounts.js", "cli-discovery", "value = judge.discover();", "value = [];",
        folder => goodCli(folder));
    controls++;
    assert.equal(calls("secret-calls").length, 0);
    safe(fs.readFileSync(store.file, "utf8"));
    assert.deepEqual(keyPresence(() => ""), keyPresence(() => undefined));
    console.log("test-jarvis-accounts: ok cases=" + cases + " controls=" + controls);
});
