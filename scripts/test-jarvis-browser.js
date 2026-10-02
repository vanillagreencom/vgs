#!/usr/bin/env node
// Real executor and action judge in J09, using schema-shaped vendor replies.
"use strict";
const { assert, fs, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const { standins, mode, calls } = require("./fixtures/jarvis/browser.js");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const file = path.join(backend, "Browser.js");
world(async () => {
    const Browser = require(file);
    const Tools = require(path.join(backend, "Tools.js"));
    const Policy = require(path.join(backend, "Policy.js"));
    const environment = { ...process.env, OPENAI_API_KEY: "fixture-secret", AGENT_BROWSER_CDP: "host-browser",
        AGENT_BROWSER_PROFILE: "/fixture/profile", AGENT_BROWSER_CONFIG: "/fixture/config", VGSH_RUNNER_PID: "fixture" };
    const marker = path.join(environment.XDG_DATA_HOME, "vgs/jarvis/browser-ready.json");
    const call = (command, args = {}) => ({ id: "browser", args: { command, args } });
    const run = (owner, command, args = {}) => new Promise(resolve => owner.record.start(call(command, args), resolve));
    async function check(implementation, name, fixture, command, args, outcome, reason) {
        mode(fixture);
        const owner = implementation.create({ environment });
        try {
            if (["click", "fill", "submit"].includes(command)) owner.record.observe(call(command, args));
            const answer = await run(owner, command, args);
            assert.equal(answer.outcome, outcome, name + ": " + answer.content);
            assert.match(answer.content, reason, name);
            return answer;
        } finally { owner.close(); }
    }
    const cases = [
        ["open", {}, "open", { url: "https://first.test/" }, "completed", /fixture-nonce.*fixture page/],
        ["read", {}, "read", {}, "completed", /fixture-nonce.*fixture page/],
        ["click", {}, "click", { ref: "@e2" }, "completed", /fixture page/],
        ["fill", {}, "fill", { ref: "@e1", text: "literal value" }, "completed", /fixture page/],
        ["submit", { type: "submit" }, "submit", { ref: "@e3" }, "completed", /fixture page/],
        ["password", { type: "password" }, "fill", { ref: "@e1", text: "private" }, "failed", /browser=password/],
        ["reference", {}, "click", { ref: "@e999" }, "failed", /browser=reference/],
        ["site-race", { attributeSite: "https://second.test/" }, "click", { ref: "@e2" }, "failed", /browser=target-changed/],
        ["redirect", { redirect: "file:///fixture/secret" }, "open", { url: "https://first.test/" }, "failed", /browser=page-url/],
        ["reply-json", { malformed: true }, "read", {}, "failed", /browser=reply-json/],
        ["command-failed", { fail: true }, "read", {}, "failed", /browser=command-failed/]
    ];
    for (const row of cases) await check(Browser, ...row);
    const forbidden = ["--cdp", "--auto-connect", "--profile", "--executable-path", "--allow-file-access", "--init-script",
        "--extension", "--args", "--config", "--session", "--action-policy", "--state", "--restore"];
    for (const flag of forbidden) {
        mode({});
        for (const request of [call(flag), call("open", { url: "https://first.test/", [flag]: "fixture" }),
            call("click", { ref: flag }), call("fill", { ref: "@e1", text: flag })]) {
            const before = calls().length;
            const owner = Browser.create({ environment });
            const probes = calls().length;
            const answer = await new Promise(resolve => owner.record.start(request, resolve));
            owner.close();
            assert.equal(answer.outcome, "failed", JSON.stringify(request));
            assert.equal(calls().length, probes, "refusal starts no vendor action");
            assert.equal(probes, before + 1, "only the version probe ran");
        }
    }
    for (const command of ["eval", "upload", "download", "state load", "cookies set", "network", "auth"]) {
        assert.equal(Tools.refine(call(command)).kind, "refuse");
    }
    for (const url of ["file:///fixture/secret", "FILE:///fixture/secret", "javascript:alert(1)"])
        assert.equal(Tools.refine(call("open", { url })).kind, "refuse");

    async function confinement(implementation, category) {
        mode({});
        const owner = implementation.create({ environment });
        try {
            await run(owner, "read");
            const row = calls().find(row => row.args.includes("snapshot"));
            assert.equal(row.env.HOME, path.join(row.env.XDG_RUNTIME_DIR, "home"));
            assert.equal(fs.readlinkSync(path.join(row.env.HOME, ".agent-browser/browsers")),
                path.join(environment.XDG_DATA_HOME, "vgs/jarvis/browser-home/.agent-browser/browsers"));
            assert.ok(row.env.XDG_RUNTIME_DIR.startsWith(path.join(environment.XDG_RUNTIME_DIR, "vgs/jarvis/browser-")));
            assert.equal(row.env.AGENT_BROWSER_CDP, undefined);
            assert.equal(row.env.AGENT_BROWSER_PROFILE, undefined);
            assert.equal(row.env.OPENAI_API_KEY, undefined);
            assert.equal(row.env.VGSH_RUNNER_PID, undefined);
            assert.notEqual(row.env.AGENT_BROWSER_CONFIG, environment.AGENT_BROWSER_CONFIG);
            const session = row.args[row.args.indexOf("--session") + 1];
            assert.match(session, /^jarvis-[0-9a-f-]+$/);
            assert.equal(row.env.AGENT_BROWSER_NAMESPACE, session);
            assert.ok(row.args.includes("--content-boundaries"));
            assert.equal(row.args[row.args.indexOf("--max-output") + 1], "16384");
            assert.equal(row.policy.default, "deny");
            for (const denied of category ? [category] : ["eval", "upload", "download", "state", "network"])
                assert.ok(row.policy.deny.includes(denied));
            assert.deepEqual(row.policy.allow, ["navigate", "snapshot", "get", "click", "fill"]);
            const second = implementation.create({ environment });
            try {
                await run(second, "read");
                const next = calls().filter(row => row.args.includes("snapshot")).at(-1);
                assert.notEqual(next.args[next.args.indexOf("--session") + 1], session);
            } finally { second.close(); }
        } finally { owner.close(); }
    }
    await confinement(Browser);
    async function bounded(implementation) {
        const answer = await check(implementation, "bounded", { text: "x".repeat(25000) }, "read", {}, "completed", /result clipped/);
        assert.ok(Buffer.byteLength(answer.content) <= 16384);
    }
    await bounded(Browser);
    function readiness(implementation, fixture, expected) {
        mode(fixture);
        assert.equal(implementation.status(environment).tone, expected);
    }
    readiness(Browser, { version: "0.37.9" }, "warning");
    mode({});
    const verified = Browser.create({ environment });
    verified.verify();
    assert.equal(Browser.status(environment).tone, "ok");
    assert.deepEqual(calls().filter(row => row.args.includes("--json")).map(row => row.args.slice(row.args.indexOf("--json") + 1)),
        [["open", "about:blank"], ["get", "url"], ["close"]]);
    readiness(Browser, { version: "0.38.2" }, "warning");
    mode({ verifyUrl: "https://wrong.test/" });
    const failed = Browser.create({ environment });
    assert.throws(() => failed.verify(), /verify-url/); failed.close();
    assert.equal(fs.existsSync(marker), false);
    mode({});
    const skill = Browser.create({ environment });
    assert.match(skill.guidance(), /fixture installed core guide/);
    assert.equal(skill.guidance(), skill.guidance());
    assert.equal(calls().filter(row => row.args[0] === "skills").length, 1, "one cache per version-owned session");
    skill.close();
    const stopped = Browser.create({ environment }); stopped.close();
    assert.equal((await run(stopped, "read")).outcome, "failed");
    // Remove the sole driver stand-in. There is no real-browser PATH fallback.
    const executable = path.join(environment.JARVIS_TEST_ROOT, "standins/agent-browser");
    const saved = fs.readFileSync(executable); fs.rmSync(executable);
    try { assert.equal(Browser.status(environment).tone, "warning"); }
    finally { fs.writeFileSync(executable, saved, { mode: 0o700 }); }

    function decision(implementation, command, fixture, grants, taint, profile = "standard") {
        mode(fixture);
        const owner = implementation.create({ environment });
        const request = call(command, { ref: command === "fill" ? "@e1" : "@e3", ...(command === "fill" ? { text: "fixture" } : {}) });
        try { return Policy.decide(request, { locked: false, profile, grants, taint,
            input: owner.record.observe(request) }); } finally { owner.close(); }
    }
    const clean = { kind: "clean" };
    assert.deepEqual(decision(Browser, "fill", {}, [], clean), { kind: "confirm", effect: "input", physical: false, scope: "site:https://first.test" });
    assert.equal(decision(Browser, "fill", {}, ["site:https://first.test"], clean).kind, "allow");
    assert.equal(decision(Browser, "fill", { site: "https://second.test/" }, ["site:https://first.test"], clean).kind, "confirm");
    assert.equal(decision(Browser, "fill", {}, ["site:https://first.test"], Policy.observe(clean, "web")).kind, "confirm");
    assert.equal(decision(Browser, "fill", { type: "password" }, [], clean, "trusted").reason, "password-target");
    const submit = implementation => assert.equal(decision(implementation, "click", { type: "submit" }, ["site:https://first.test"], clean, "trusted").effect, "external");
    submit(Browser);
    const remote = Policy.recipients({ conversation: "browser", profile: "standard", cloudVision: "ask",
        brain: { kind: "network", provider: "fixture", account: "fixture", origin: "https://provider.test" }, speech: [{ kind: "local", provider: "local", account: "" }] });
    assert.equal(Policy.release(Policy.item("fixture page", ["web"]), remote).kind, "ask");

    async function cancellation(implementation) {
        mode({ delayMs: 1000 });
        const owner = implementation.create({ environment });
        const result = run(owner, "open", { url: "https://first.test/" });
        // Wait for the synthetic child to record that it reached open.
        for (let n = 0; !calls().some(row => row.args.includes("open")); n++) {
            assert.ok(n < 500, "the fixture reaches its pending command");
            await new Promise(resolve => setTimeout(resolve, 10));
        }
        const directory = calls().find(row => row.args.includes("open")).env.XDG_RUNTIME_DIR;
        owner.record.cancel();
        assert.equal((await result).outcome, "failed", "cancel ends the actual CLI child");
        assert.equal(fs.existsSync(path.join(process.env.JARVIS_TEST_ROOT, "browser-open-completed")), false, "cancel precedes natural child completion");
        assert.ok(calls().some(row => row.args.at(-1) === "close"), "cancel closes the vendor session");
        assert.equal(fs.existsSync(directory), false, "cancel releases owned session files");
        owner.close();
    }
    await cancellation(Browser);
    async function lifecycle(implementation, edge) {
        mode({});
        fs.mkdirSync(path.dirname(marker), { recursive: true });
        fs.writeFileSync(marker, JSON.stringify({ version: "0.38.1" }));
        const records = {};
        const lease = implementation.install({ environment, router: { register: (id, record) => { records[id] = record; } } });
        assert.ok(lease);
        lease.sync({ gen: 1, conversation: { kind: "started" } });
        await new Promise(resolve => records.browser.start(call("read"), resolve));
        const first = calls().find(row => row.args.includes("snapshot"));
        if (edge === "generation") lease.sync({ gen: 2, conversation: { kind: "started" } });
        else if (edge === "end") lease.sync({ gen: 1, conversation: { kind: "ended" } });
        else lease.close();
        assert.equal(fs.existsSync(first.env.XDG_RUNTIME_DIR), false, edge + " releases session files");
        assert.equal(calls().filter(row => row.args.at(-1) === "close").length, 1, edge + " closes vendor session");
        if (edge !== "lease") {
            lease.sync({ gen: 2, conversation: { kind: "started" } });
            await new Promise(resolve => records.browser.start(call("read"), resolve));
            const second = calls().filter(row => row.args.includes("snapshot")).at(-1);
            assert.notEqual(first.env.AGENT_BROWSER_NAMESPACE, second.env.AGENT_BROWSER_NAMESPACE);
        }
        lease.close();
    }
    for (const edge of ["generation", "end", "lease"]) await lifecycle(Browser, edge);

    function setupAfterStart(implementation) {
        mode({}); fs.rmSync(marker, { force: true });
        const records = {};
        const lease = implementation.install({ environment, router: { register(id, record) { records[id] = record; } } });
        assert.equal(records.browser, undefined, "unverified browser is not offered");
        lease.sync({ gen: 1, conversation: { kind: "ended" } });
        fs.writeFileSync(marker, JSON.stringify({ version: "0.38.1" }));
        lease.sync({ gen: 2, conversation: { kind: "started" } });
        assert.equal(typeof records.browser?.start, "function", "setup becomes available to the next conversation");
        fs.rmSync(marker, { force: true });
        assert.equal(records.browser.observe(call("fill", { ref: "@e1", text: "fixture" })), undefined,
            "stale readiness produces an unavailable input target");
        assert.throws(() => records.browser.start(call("read"), () => {}), /unverified/,
            "a removed or stale verification cannot start a new session");
        lease.close();
    }
    setupAfterStart(Browser);
    let controls = 0;
    async function control(name, needle, replacement, check) { await mutant(file, name, needle, replacement, check); controls++; }
    const one = name => implementation => check(implementation, ...cases.find(row => row[0] === name));
    await control("setup-after-start", 'if (changed && !ended) prepare();', 'void changed;', setupAfterStart);
    await control("live-verification", 'if (status(environment).tone !== "ok") throw new Error("jarvis: browser=unverified");',
        'if (false) throw new Error("jarvis: browser=unverified");', setupAfterStart);
    await control("unverified-observation", 'try { return owner().record.observe(call); } catch { return undefined; }',
        'return owner().record.observe(call);', setupAfterStart);
    await control("private-home", "HOME: privateHome, LANG:", "HOME: environment.HOME, LANG:", confinement);
    await control("private-session", 'const session = "jarvis-" + crypto.randomUUID();', 'const session = "jarvis-fixed";', confinement);
    await control("neutral-config", "AGENT_BROWSER_CONFIG: configFile", "AGENT_BROWSER_CONFIG: environment.AGENT_BROWSER_CONFIG", confinement);
    await control("scrub-env", "const env = { PATH:", "const env = { ...environment, PATH:", confinement);
    await control("boundaries", '"--content-boundaries", "--max-output"', '"--debug", "--max-output"', confinement);
    await control("max-output", 'String(OUTPUT_BYTES), "--json"', '"999999", "--json"', confinement);
    for (const category of ["eval", "upload", "download", "state", "network"])
        await control("deny-" + category, '"' + category + '"', '"fixture-' + category + '"', implementation => confinement(implementation, category));
    await control("output-bound", "bytes.length <= OUTPUT_BYTES", "true", bounded);
    await control("password", "if (fresh.target.password) throw", "if (false) throw", one("password"));
    await control("reference", "if (!ref || typeof ref.role !== \"string\") throw", "if (false) throw", one("reference"));
    await control("page-url", 'if (refined.kind !== "call") throw new Error("jarvis: browser=page-url");',
        'if (false) throw new Error("jarvis: browser=page-url");', one("redirect"));
    await control("target-race", "site !== page(before) ||", "false ||", one("site-race"));
    await control("submit", 'type === "submit" || type === "image"', 'type === "fixture-submit" || type === "image"', implementation => {
        // textbox role isolates explicit type from the button default rule.
        mode({ type: "submit" }); const owner = implementation.create({ environment });
        try { assert.equal(owner.record.observe(call("click", { ref: "@e1" })).target.submit, true); } finally { owner.close(); }
    });
    await control("version-floor", "found[1] < floor[1]", "false", implementation => {
        mode({ version: "0.37.9" }); assert.throws(() => implementation.create({ environment }), /version-floor/);
    });
    await control("verified-version", "marker.version !== installed", "false", implementation => {
        fs.mkdirSync(path.dirname(marker), { recursive: true }); fs.writeFileSync(marker, JSON.stringify({ version: "0.38.1" }));
        readiness(implementation, { version: "0.38.2" }, "warning");
    });
    await control("verification", 'answer.data.url !== "about:blank"', "false", implementation => {
        mode({ verifyUrl: "https://wrong.test/" }); const owner = implementation.create({ environment });
        try { assert.throws(() => owner.verify(), /verify-url/); } finally { owner.close(); }
    });
    function failedClose(implementation) {
        mode({ closeFail: true });
        const owner = implementation.create({ environment });
        assert.throws(() => owner.verify(), /close-failed/);
        assert.equal(fs.existsSync(marker), false, "failed close cannot leave ready");
    }
    failedClose(Browser);
    await control("verified-close", 'try { decode(result); } catch { throw new Error("jarvis: browser=close-failed"); }',
        'void result;', failedClose);
    await mutant(path.join(backend, "Policy.js"), "submit-effect", 'if (input.target.submit === true) effect = "external";',
        'if (false && input.target.submit === true) effect = "external";', implementation => {
            const request = call("click", { ref: "@e1" });
            assert.equal(implementation.decide(request, { locked: false, profile: "trusted", taint: clean, grants: [],
                input: { target: { kind: "site", id: "https://first.test", password: false, submit: true } } }).effect, "external");
        }); controls++;
    await mutant(path.join(backend, "Tools.js"), "fill-flag", 'pattern: "^(?!-)[^\\\\u0000]*$"', 'pattern: "^[^\\\\u0000]*$"', implementation => {
        assert.equal(implementation.refine(call("fill", { ref: "@e1", text: "--cdp" })).kind, "refuse");
    }); controls++;
    await control("cancel-child", 'if (active !== null) active.kill("SIGKILL");', 'if (false && active !== null) active.kill("SIGKILL");', cancellation);
    await control("generation-close", 'if (generation !== state.gen || state.conversation.kind === "ended") clear();',
        'if (state.conversation.kind === "ended") clear();', implementation => lifecycle(implementation, "generation"));
    await control("conversation-close", 'if (generation !== state.gen || state.conversation.kind === "ended") clear();',
        'if (generation !== state.gen) clear();', implementation => lifecycle(implementation, "end"));
    await control("lease-close", 'close() { closed = true; clear(); }', 'close() { closed = true; }', implementation => lifecycle(implementation, "lease"));
    console.log("test-jarvis-browser: ok cases=" + cases.length + " controls=" + controls);
}, standins);
