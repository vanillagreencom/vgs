#!/usr/bin/env node
// Synthetic protocol and argv fixtures for the plan's input family. Every
// child uses the J09 scratch world; no live desktop, authentication or device.
"use strict";
const { assert, fs, path, tree, world, seed, asyncControl, mutant } = require("./fixtures/jarvis/policy.js");
const { load } = require("../bin/lib/qml-library.js");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const file = path.join(backend, "Input.js");
const Policy = require(path.join(backend, "Policy.js"));
const Tools = require(path.join(backend, "Tools.js"));

world(() => main().catch(error => { console.error(error); process.exitCode = 1; }), standins => {
    for (const name of ["wtype", "wlrctl", "ydotool"]) {
        const script = path.join(standins, name);
        fs.writeFileSync(script, '#!/usr/bin/env node\nconst fs=require("node:fs"); const path=require("node:path"); const name=path.basename(process.argv[1]); const args=process.argv.slice(2); fs.appendFileSync(process.env.INPUT_LOG,JSON.stringify([name,args])+"\\n"); if(process.env.INPUT_FAIL===name && (!process.env.INPUT_FAIL_INPUT_ONLY || args.at(-1)!==""))process.exit(1);\n');
        fs.chmodSync(script, 0o700);
    }
});

async function main() {
    seed();
    const root = process.env.JARVIS_TEST_ROOT;
    let count = 0;
    function make(module = require(file), options = {}) {
        const log = path.join(root, "input-" + ++count + ".jsonl");
        const requests = [];
        let target = { kind: "application", id: "fixture.editor", window: "0xa1" };
        let cursor = { x: 4, y: 5 };
        let keycodes = [38, 9];
        let effective = [{ modifiers: ["SUPER"], keycode: 108, keysym: "Alt_R", codepoint: 0 }];
        let emittedEffective = null;
        let moving = false;
        let observed = 0;
        let heldReply, signalHeld, heldOnce = false;
        const held = new Promise(resolve => { signalHeld = resolve; });
        const request = (kind, args, timeout, done) => {
            requests.push([kind, args]);
            let data;
            if (kind === "input.observe") { observed++; data = { ok: true, target: moving && options.movedTarget ? options.movedTarget : target,
                cursor: options.constrained && moving ? { x: 0, y: 0 } : cursor }; }
            else if (kind === "input.keys") data = { ok: true,
                keys: args.map((value, i) => ({ modifiers: value.includes("+") ? ["SUPER"] : [], keycode: keycodes[i], keysym: i === 0 ? "a" : "Escape", codepoint: i === 0 ? 97 : 27 })).concat(effective),
                translation: args.map((value, i) => ({ modifiers: value.includes("+") ? ["SUPER"] : [], keycode: keycodes[i], keysym: i === 0 ? "a" : "Escape", codepoint: i === 0 ? 97 : 27 })).concat(emittedEffective || effective),
                effective: effective.map(key => key.modifiers.concat(["code:" + key.keycode]).join("+")) };
            else if (kind === "compositor.moveCursor") { cursor = { x: args[0], y: args[1] }; moving = true; data = null; }
            else throw new Error("fixture-request-kind");
            if (kind === "input.observe" && moving && options.beforeDelivery) {
                const x = data.cursor.x;
                data.cursor = { y: data.cursor.y, get x() { options.beforeDelivery(); return x; } };
            }
            const reply = () => queueMicrotask(() => done(options.unread || options.readbackFailure && observed > 1 ? { kind: "timeout" } : { kind: "answer", answer: "ok", data }));
            if (!heldOnce && moving && options.hold === kind) { heldOnce = true; heldReply = reply; signalHeld(); }
            else reply();
        };
        const owner = module.create({ request, timeoutMs: 1000,
            environment: { PATH: process.env.PATH, INPUT_LOG: log, INPUT_FAIL: options.fail || "", INPUT_FAIL_INPUT_ONLY: options.inputOnly ? "1" : "" },
            commands: options.commands || ["wtype", "wlrctl", "ydotool"] });
        const writes = () => fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n").map(JSON.parse) : [];
        const run = (call, record) => new Promise(resolve => record.start(call, resolve, input => Policy.decide(call, { ...context, input })));
        return { owner, writes, run, requests, held, release: () => heldReply(),
            target(value) { target = value; }, effective(value) { effective = value; }, globalEffective(value) { emittedEffective = value; }, keycodes(value) { keycodes = value; } };
    }
    const context = { locked: false, profile: "trusted", taint: { kind: "clean" }, grants: [] };
    function refined(id, args) { const value = Tools.refine({ id, args }); assert.equal(value.kind, "call"); return value.call; }
    async function transport(module, id, args, want) {
        const h = make(module);
        try {
            const record = await h.owner.ready();
            const call = refined(id, args);
            const input = await record.observe(call);
            assert.equal(Policy.decide(call, { ...context, input }).kind, "allow");
            const answer = await h.run(call, record);
            assert.equal(answer.outcome, "unknown", answer.content);
            assert.deepEqual(h.writes().at(-1), want);
            assert.ok(h.requests.filter(([kind]) => kind === "input.observe").length >= 2);
        } finally { h.owner.close(); }
    }
    const argvRows = [
        ["input.text", { text: "-literal\ntext" }, ["wtype", ["--", "-literal\ntext"]]],
        ["input.key", { chord: "SUPER+A" }, ["wtype", ["-M", "logo", "-k", "a", "-m", "logo"]]],
        ["input.click", { x: 50, y: 60, button: "right" }, ["wlrctl", ["pointer", "click", "right"]]],
        ...["up", "down", "left", "right"].map(direction => ["input.scroll", { x: 50, y: 60, direction, steps: 3 },
            ["wlrctl", ["pointer", "scroll", String(direction === "up" ? -3 : direction === "down" ? 3 : 0),
                String(direction === "left" ? -3 : direction === "right" ? 3 : 0)]]])
    ];
    for (const row of argvRows) await transport(require(file), ...row);
    const control = asyncControl(file);
    await control("wtype-literal", '["--", a.text]', '["-k", a.text]', module => transport(module, ...argvRows[0]));
    await control("wtype-modifiers", 'SUPER: "logo"', 'SUPER: "alt"', module => transport(module, ...argvRows[1]));
    await control("pointer-click", '["pointer", "click", a.button]', '["pointer", "click", "left"]', module => transport(module, ...argvRows[2]));
    await control("pointer-scroll", 'a.direction === "down" ? a.steps', 'a.direction === "down" ? -a.steps', module => transport(module, ...argvRows[4]));

    async function refusal(module, options, configure, id, args, reason, judge = Policy) {
        const h = make(module, options);
        try {
            const record = await h.owner.ready();
            if (configure) configure(h);
            const call = refined(id, args);
            const input = await record.observe(call);
            assert.equal(judge.decide(call, { ...context, input }).reason, reason);
            assert.equal(h.writes().filter(([, args]) => args.includes("click") || args.includes("-k") || args.includes("literal")).length, 0);
        } finally { h.owner.close(); }
    }
    const ownGlobal = h => h.globalEffective([{ modifiers: ["SUPER"], keycode: 9, keysym: "Escape", codepoint: 27 }]);
    await refusal(require(file), {}, ownGlobal, "input.key", { chord: "SUPER+A" }, "jarvis-chord");
    await mutant(path.join(backend, "Policy.js"), "own-emitted-code", 'if (key.emittedEffective.some(bound => sameChord(key.emitted, bound)))',
        'if (false && key.emittedEffective.some(bound => sameChord(key.emitted, bound)))', judge =>
            refusal(require(file), {}, ownGlobal, "input.key", { chord: "SUPER+A" }, "jarvis-chord", judge));
    const ownText = h => h.effective([{ modifiers: [], keycode: 36, keysym: "Return", codepoint: 13 }]);
    await refusal(require(file), {}, ownText, "input.text", { text: "literal" }, "own-shortcut");
    await mutant(path.join(backend, "Policy.js"), "text-own-bind", 'bound.modifiers.length === 0', 'false && bound.modifiers.length === 0', judge =>
        refusal(require(file), {}, ownText, "input.text", { text: "literal" }, "own-shortcut", judge));
    const heldNative = h => h.effective([{ modifiers: ["SUPER"], keycode: 38, keysym: "a", codepoint: 97 }]);
    for (const configure of [heldNative, ownGlobal])
        await refusal(require(file), {}, configure, "input.key", { chord: "A" }, "jarvis-chord");
    await mutant(path.join(backend, "Policy.js"), "physical-modifier-key", 'left.modifiers.every(mod => right.modifiers.includes(mod))',
        'left.modifiers.slice().sort().join(",") === right.modifiers.slice().sort().join(",")', judge =>
            refusal(require(file), {}, heldNative, "input.key", { chord: "A" }, "jarvis-chord", judge));
    const textCases = [
        ["native symbol with physical SUPER", "literal", "native", { modifiers: ["SUPER"], keycode: 46, keysym: "l", codepoint: 108 }],
        ["global symbol with physical CTRL", "α", "global", { modifiers: ["CTRL"], keycode: 38, keysym: "Greek_alpha", codepoint: 0x3b1 }],
        ["uppercase symbol", "A", "native", { modifiers: ["SUPER"], keycode: 38, keysym: "a", codepoint: 97 }],
        ["generated escape code", "x", "global", { modifiers: ["SUPER"], keycode: 9, keysym: "Escape", codepoint: 27 }],
        ["last generated code", "😀α😀x", "native", { modifiers: ["SUPER"], keycode: 11, keysym: "2", codepoint: 50 }],
        ["newline maps to Return", "\n", "native", { modifiers: ["SUPER"], keycode: 36, keysym: "Return", codepoint: 13 }],
        ["tab symbol", "\t", "native", { modifiers: ["SUPER"], keycode: 23, keysym: "Tab", codepoint: 9 }],
        ["escape symbol", "\x1b", "native", { modifiers: ["SUPER"], keycode: 66, keysym: "Escape", codepoint: 27 }],
        ["UTF-8 replacement symbol", "\ud800", "native", { modifiers: ["SUPER"], keycode: 38, keysym: "Ufffd", codepoint: 0xfffd }]
    ];
    const textCase = async (row, judge = Policy) => {
        const [, text, map, bound] = row;
        await refusal(require(file), {}, h => map === "native" ? h.effective([bound]) : h.globalEffective([bound]),
            "input.text", { text }, "own-shortcut", judge);
    };
    for (const row of textCases) await textCase(row);
    await mutant(path.join(backend, "Policy.js"), "text-generated-codes", 'bound.keycode >= 9 && bound.keycode < 9 + symbols.length',
        'false', judge => textCase(textCases[4], judge));
    await mutant(path.join(backend, "Policy.js"), "text-generated-symbols", 'bound.codepoint !== 0 && symbols.some(symbol =>',
        'false && symbols.some(symbol =>', judge => textCase(textCases[0], judge));
    await mutant(path.join(backend, "Policy.js"), "text-newline-symbol", 'symbol === "\\n" ? "\\r" : symbol',
        'symbol', judge => textCase(textCases[5], judge));
    for (const [text, bound] of [["😀😀", { modifiers: ["SUPER"], keycode: 10, codepoint: 0 }],
        ["abc", { modifiers: ["SUPER"], keycode: 12, codepoint: 0 }], ["x", { modifiers: ["SUPER"], keycode: 8, codepoint: 0 }]]) {
        const h = make(); const record = await h.owner.ready(); h.effective([{ ...bound, keysym: "fixture" }]);
        const call = refined("input.text", { text });
        assert.equal(Policy.decide(call, { ...context, input: await record.observe(call) }).kind, "allow", "only actual generated raw codes match");
        h.owner.close();
    }
    await refusal(require(file), {}, null, "input.text", { text: "x".repeat(4097) }, "input-size");
    await control("text-bound", 'Buffer.byteLength(a.text) > 4096', 'false && Buffer.byteLength(a.text) > 4096', module =>
        refusal(module, {}, null, "input.text", { text: "x".repeat(4097) }, "input-size"));
    for (const kind of ["vgs", "lock", "polkit"]) await refusal(require(file), {}, h => h.target({ kind, id: kind }), "input.text", { text: "literal" }, "protected-target");
    for (const profile of ["cautious", "standard"]) {
        const h = make(); const record = await h.owner.ready(); h.target({ kind: "terminal", id: "fixture.terminal" });
        const call = refined("input.text", { text: "literal" });
        assert.equal(Policy.decide(call, { ...context, profile, input: await record.observe(call) }).reason, "terminal-text"); h.owner.close();
    }
    const terminal = make(); const terminalRecord = await terminal.owner.ready(); terminal.target({ kind: "terminal", id: "fixture.terminal" });
    const text = refined("input.text", { text: "literal" });
    assert.deepEqual(Policy.decide(text, { ...context, input: await terminalRecord.observe(text) }), { kind: "confirm", effect: "destructive", physical: true }); terminal.owner.close();

    async function moved(module, options, reason) {
        const h = make(module, options);
        try {
            const record = await h.owner.ready(); const call = refined("input.click", { x: 50, y: 60, button: "left" });
            await record.observe(call); const answer = await h.run(call, record);
            assert.equal(answer.outcome, "failed"); assert.equal(answer.content, reason);
            assert.equal(h.writes().filter(([, args]) => args.includes("click")).length, 0);
        } finally { h.owner.close(); }
    }
    const targetChange = { movedTarget: { kind: "vgs", id: "vgs:notice" } };
    await moved(require(file), targetChange, "input-target-changed");
    await control("fresh-target", 'JSON.stringify(input.target) !== JSON.stringify(prior.target)', 'false && JSON.stringify(input.target) !== JSON.stringify(prior.target)', module => moved(module, targetChange, "input-target-changed"));
    await moved(require(file), { constrained: true }, "input-cursor-unverified");
    await control("cursor-readback", 'input.cursor.x !== call.args.x || input.cursor.y !== call.args.y', 'false', module => moved(module, { constrained: true }, "input-cursor-unverified"));
    const fallback = make(undefined, { commands: ["ydotool"] }); const fallbackRecord = await fallback.owner.ready();
    assert.deepEqual(fallbackRecord.commands, ["ydotool"]);
    const click = refined("input.click", { x: 50, y: 60, button: "middle" }); await fallbackRecord.observe(click); await fallback.run(click, fallbackRecord);
    assert.deepEqual(fallback.writes().at(-1), ["ydotool", ["click", "0xC2"]]); fallback.owner.close();
    async function unavailable(module) { const h = make(module, { commands: ["ydotool"], fail: "ydotool" });
        assert.deepEqual((await h.owner.ready()).commands, []); h.owner.close(); }
    await unavailable(require(file));
    await control("running-daemon", 'await command("ydotool", ["debug"]); pointer = "ydotool";', 'await Promise.resolve(); pointer = "ydotool";', unavailable);
    const unread = make(undefined, { unread: true }); const unreadRecord = await unread.owner.ready();
    assert.equal((await unreadRecord.observe(text)).refusal, "input-request:timeout"); unread.owner.close();
    async function readback(module) {
        const delivered = make(module, { readbackFailure: true });
        const deliveredRecord = await delivered.owner.ready();
        await deliveredRecord.observe(text);
        const deliveredResult = await delivered.run(text, deliveredRecord);
        assert.equal(deliveredResult.outcome, "unknown");
        assert.match(deliveredResult.content, /Readback unavailable/);
        delivered.owner.close();
    }
    await readback(require(file));
    await control("delivered-readback", 'catch (error) { detail = "Readback unavailable: " + error.message + "."; }', 'catch (error) { throw error; }', readback);
    async function partial(module) {
        const h = make(module, { fail: "wtype", inputOnly: true });
        const record = await h.owner.ready();
        await record.observe(text);
        const answer = await h.run(text, record);
        assert.equal(answer.outcome, "unknown");
        assert.match(answer.content, /Delivery may be partial/);
        h.owner.close();
    }
    await partial(require(file));
    await control("partial-transport", 'if (!error.deliveryPossible) throw error;', 'throw error;', partial);
    await helpEvidence();
    await routerEvidence();
    await pointerAuthority(make, refined);
    console.log("jarvis-input: pass argv, target, own-bind, terminal, readiness and serial-observation controls");
}

async function pointerAuthority(makeInput, refined) {
    const Session = load(path.join(tree, "shell/plugins/vgs.jarvis/Session.js"));
    const { SessionRunner, unavailable } = require(path.join(backend, "session-runner.js"));
    const Router = require(path.join(backend, "ToolRouter.js"));
    const actions = [["input.click", { x: 50, y: 60, button: "left" }],
        ["input.scroll", { x: 50, y: 60, direction: "down", steps: 2 }]];
    const changes = ["lock", "stop", "generation", "expiry", "policy"];
    async function run(module, transport, hold, change, action = actions[0], finalOnly = false) {
        let at = 0, transcript, locked = false;
        const ports = { ...unavailable(), mute: { store() {} },
            capture: { open: (e, done) => done(), close: (e, done) => done(), collect: (e, done) => { transcript = done; } },
            brain: { send() {}, cancel: (e, done) => done(), close() {}, outcome() {} } };
        const runner = new SessionRunner(Session, ports, { now: () => at, set: () => ({}), clear() {} }, () => {});
        let finish;
        const completed = new Promise(resolve => { finish = resolve; });
        const router = module.create({ session: Session, state: () => runner.state, dispatch: event => runner.dispatch(event),
            context: () => ({ profile: "trusted", locked, denied: null }),
            audit: { record: () => ({ kind: "recorded" }), before: (row, action) => { action(); return { kind: "recorded" }; }, cleanup: (reason, action) => action() },
            result() {} });
        Object.assign(ports, router.ports);
        const changeState = () => {
            switch (change) {
            case "lock": locked = true; runner.dispatch({ type: "snapshot", engine: "chained", locked: true, configured: true, settings: {} }); break;
            case "stop": runner.dispatch({ type: "stop" }); break;
            case "generation": runner.dispatch({ type: "snapshot", engine: "chained", locked: false, configured: true, settings: { mode: "toggle" } }); break;
            case "expiry": at += 1001; break;
            case "policy": locked = true; break;
            default: throw new Error("fixture-change");
            }
        };
        const input = makeInput(undefined, { commands: [transport], hold: finalOnly ? undefined : hold,
            beforeDelivery: finalOnly ? changeState : undefined });
        try {
            const record = await input.owner.ready();
            router.register("input", { ...record, timeoutMs: 1000,
                start(call, done, authority) { record.start(call, answer => { done(answer); finish(); }, authority); } });
            runner.dispatch({ type: "snapshot", engine: "chained", locked: false, configured: true, settings: {} }); runner.dispatch({ type: "indicator", shown: true });
            runner.dispatch({ type: "talk-down" }); transcript("final", "fixture");
            const [id, args] = action;
            assert.equal(refined(id, args).id, id);
            const proposed = router.route({ id: "pointer", tool: id, arguments: args }, { gen: runner.state.gen, op: runner.state.turn.op });
            assert.equal((await proposed).kind, "proposed");
            if (!finalOnly) {
                await input.held;
                assert.equal(runner.state.action.kind, "running", "preparation retains its serial action");
                assert.equal(router.route({ id: "other", tool: id, arguments: args }, { gen: runner.state.gen, op: runner.state.turn.op }).reason, "busy");
                changeState(); input.release();
            }
            await completed;
            const delivery = input.writes().filter(([, args]) => args[0] === "click" || args.includes("click")
                || args.includes("--wheel") || args[0] === "pointer" && args[1] === "scroll" && args.slice(2).some(value => value !== "0"));
            assert.deepEqual(delivery, [], transport + " " + hold + " " + change + " refuses delayed " + id);
        } finally { runner.close(); input.owner.close(); }
    }
    for (const transport of ["wlrctl", "ydotool"])
        for (const hold of ["compositor.moveCursor", "input.observe"])
            for (const change of changes)
                for (const action of actions) await run(Router, transport, hold, change, action);
    await mutant(path.join(backend, "ToolRouter.js"), "pointer-final-authority",
        'const answer = authorize(value, e, decide(value, input));', 'const answer = { kind: "allow" };',
        module => run(module, "wlrctl", "input.observe", "lock"));
    // The cursor getter represents synchronous readback checking after the
    // last awaited reply. Delivery must also check after that work.
    await run(Router, "wlrctl", "input.observe", "policy", actions[0], true);
    await mutant(file, "input-final-launch", 'const [name, args] = argv(call, input);\n        checkpoint();',
        'const [name, args] = argv(call, input);', async module => {
            const original = makeInput;
            makeInput = (unused, options) => original(module, options);
            try { await run(Router, "wlrctl", "input.observe", "policy", actions[0], true); }
            finally { makeInput = original; }
        });
}

async function routerEvidence() {
    const Session = load(path.join(tree, "shell/plugins/vgs.jarvis/Session.js"));
    const { SessionRunner, unavailable } = require(path.join(backend, "session-runner.js"));
    const Router = require(path.join(backend, "ToolRouter.js"));
    function make(module = Router, profile = "standard") {
        let at = 0, transcript, answer;
        const results = [], starts = [];
        const ports = { ...unavailable(), mute: { store() {} }, capture: { open: (e, done) => done(), close: (e, done) => done(), collect: (e, done) => { transcript = done; } },
            brain: { send() {}, cancel: (e, done) => done(), close() {}, outcome() {} } };
        const runner = new SessionRunner(Session, ports, { now: () => at, set: () => ({}), clear() {} }, () => {});
        const router = module.create({ session: Session, state: () => runner.state, dispatch: event => runner.dispatch(event),
            context: () => ({ profile, locked: false, denied: null }),
            audit: { record: () => ({ kind: "recorded" }), before: (row, action) => { action(); return { kind: "recorded" }; }, cleanup: (reason, action) => action() }, result: value => results.push(value) });
        Object.assign(ports, router.ports);
        router.register("input", { commands: ["wtype"], timeoutMs: 1000, cancellable: false,
            observe: () => new Promise(resolve => { answer = resolve; }), start: (call, done) => { starts.push(call); done({ outcome: "completed", content: "fixture" }); } });
        runner.dispatch({ type: "snapshot", engine: "chained", locked: false, configured: true, settings: {} }); runner.dispatch({ type: "indicator", shown: true });
        runner.dispatch({ type: "talk-down" }); transcript("final", "fixture user");
        const route = () => router.route({ id: "input-call", tool: "input.text", arguments: { text: "literal" } }, { gen: runner.state.gen, op: runner.state.turn.op });
        return { runner, router, starts, route, resolve: () => answer({ target: { kind: "application", id: "editor" }, text: { effective: [] } }), advance: n => { at += n; } };
    }
    const h = make(); const observed = h.route(); assert.equal(h.route().reason, "busy");
    h.resolve(); const hold = await observed; assert.equal(hold.kind, "held");
    assert.equal(h.route().reason, "busy"); assert.deepEqual(h.starts, [], "approval controls receive no input while held");
    h.runner.close();
    async function stale(module) { const h = make(module); const observed = h.route();
        h.advance(60001); h.resolve(); assert.equal((await observed).reason, "stale-turn"); assert.deepEqual(h.starts, []); h.runner.close(); }
    async function expiredStart(module) {
        const h = make(module, "trusted");
        const proposed = h.route(); h.resolve();
        assert.equal((await proposed).kind, "proposed");
        h.advance(1001); h.resolve();
        await Promise.resolve(); await Promise.resolve();
        assert.deepEqual(h.starts, [], "an expired action cannot send delayed input");
        h.runner.close();
    }
    await expiredStart(Router);
    await mutant(path.join(backend, "ToolRouter.js"), "async-action-expiry", 'freshState.action.limit.kind !== "pending"', 'false', expiredStart);
    await stale(Router);
    await mutant(path.join(backend, "ToolRouter.js"), "async-stale-turn", 'if (current.gen !== turn.gen || current.turn.kind !== "thinking" || current.turn.op !== turn.op)',
        'if (false && (current.gen !== turn.gen || current.turn.kind !== "thinking" || current.turn.op !== turn.op))', stale);
}

async function helpEvidence() {
    const Help = require(path.join(backend, "ComputerHelp.js"));
    const dir = path.join(process.env.JARVIS_TEST_ROOT, "computer-help");
    fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dir, "input.md"), "Fixture guidance\n");
    const check = module => {
        const owner = module.create(dir); assert.deepEqual(owner.topics, ["input"]);
        let result; owner.start({ id: "help", args: { topic: "input" } }, value => { result = value; });
        assert.deepEqual(result, { outcome: "completed", content: "Fixture guidance" });
        owner.start({ id: "help", args: { topic: "windows" } }, value => { result = value; });
        assert.equal(result.outcome, "failed");
    };
    check(Help);
    await mutant(path.join(backend, "ComputerHelp.js"), "help-uninstalled", 'if (!topics.includes(topic)) throw new Error("help-topic-unavailable");', ';', module => {
        const owner = module.create(dir); let result;
        owner.start({ id: "help", args: { topic: "windows" } }, value => { result = value; });
        assert.equal(result.content, "help-read:help-topic-unavailable");
    });
    for (const [value, reason] of [["x".repeat(8193), "help-file-too-large"], ["", "help-file-empty"]]) {
        fs.writeFileSync(path.join(dir, "input.md"), value);
        let answer; Help.create(dir).start({ id: "help", args: { topic: "input" } }, value => { answer = value; });
        assert.equal(answer.content, "help-read:" + reason);
    }
    fs.writeFileSync(path.join(dir, "input.md"), "x".repeat(8193));
    await mutant(path.join(backend, "ComputerHelp.js"), "help-bound", 'if (size > LIMIT) throw new Error("help-file-too-large");', ';', module => {
        let answer; module.create(dir).start({ id: "help", args: { topic: "input" } }, value => { answer = value; });
        assert.equal(answer.outcome, "failed");
    });
    fs.writeFileSync(path.join(dir, "input.md"), "");
    await mutant(path.join(backend, "ComputerHelp.js"), "help-empty", 'if (content === "") throw new Error("help-file-empty");', ';', module => {
        let answer; module.create(dir).start({ id: "help", args: { topic: "input" } }, value => { answer = value; });
        assert.equal(answer.outcome, "failed");
    });
}
