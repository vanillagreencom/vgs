#!/usr/bin/env node
// Synthetic action contracts from the Jarvis plan §3.7, 2026-10-01.
// The real reducer, runner, Policy and Audit run only in the J09 scratch world.
"use strict";
const { assert, fs, path, tree, world, seed, mutant, qmlCopy } = require("./fixtures/jarvis/policy.js");
const { load } = require("../bin/lib/qml-library.js");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const routerFile = path.join(backend, "ToolRouter.js");
const sessionFile = path.join(tree, "shell/plugins/vgs.jarvis/Session.js");

world(() => {
    const Router = require(routerFile);
    const Session = load(sessionFile);
    const { SessionRunner, unavailable } = require(path.join(backend, "session-runner.js"));
    const Audit = require(path.join(backend, "Audit.js"));
    const Denied = require(path.join(backend, "Denied.js"));
    const fixtures = seed();
    const cleanups = [];
    let controls = 0;
    function make(implementation = Router, session = Session, options = {}) {
        let at = 0, locked = false, transcript;
        const starts = [], answers = [], results = [], records = [];
        const timers = new Map();
        const directory = fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "router-"));
        const audit = Audit.create({ state: directory, now: () => Date.UTC(2026, 9, 1) });
        const rows = () => fs.existsSync(path.join(directory, "audit/2026-10-01.jsonl"))
            ? fs.readFileSync(path.join(directory, "audit/2026-10-01.jsonl"), "utf8").trim().split("\n").map(JSON.parse) : [];
        const ports = { ...unavailable(), mute: { store() {} },
            capture: { open: (e, done) => done(), close: (e, done) => done(), collect: (e, done) => { transcript = done; } },
            brain: { send() {}, cancel: (e, done) => {
                if (options.ackCancel !== false) done();
            }, close() {}, outcome: value => results.push(value) } };
        const runner = new SessionRunner(session, ports,
            { now: () => at, set: (fn, ms) => {
                const timer = {};
                timers.set(timer, { fn, deadline: at + ms });
                return timer;
            }, clear: timer => timers.delete(timer) }, () => {});
        const denied = () => Denied.create(fixtures.roots);
        let target = { kind: "application", id: "editor" };
        const router = implementation.create({ session, state: () => runner.state,
            dispatch: e => runner.dispatch(e), context: () => ({
                profile: options.profile ?? "standard", locked, denied: denied() }),
            audit, result: value => results.push(value) });
        Object.assign(ports, router.ports);
        for (const executor of ["windows", "compositor", "files", "input", "sandbox", "browser"]) {
            router.register(executor, { commands: ["hyprctl", "wtype", "wlrctl", "bwrap", "agent-browser"],
                timeoutMs: 1000, cancellable: true,
                observe: () => ({ target }),
                start: (call, done) => {
                    records.push(rows().at(-1));
                    starts.push(call);
                    answers.push(done);
                }, cancel: call => starts.push({ cancelled: call.id }) });
        }
        runner.dispatch({ type: "snapshot", locked: false, configured: true, echoCancel: false, settings: {} });
        runner.dispatch({ type: "indicator", shown: true });
        function newTurn() { runner.dispatch({ type: "talk-down" }); transcript("final", "fixture user"); }
        newTurn();
        const dispatch = e => runner.dispatch(e);
        const call = (tool, args = {}, identity = runner.state.turn) =>
            router.route({ kind: "tool-call", id: "model-" + tool, tool, arguments: args }, { gen: identity.gen, op: identity.op });
        const show = () => dispatch({ type: "shown", gen: runner.state.gen,
            op: runner.state.approval.op, id: runner.state.approval.id });
        const confirm = (extra = {}) => dispatch({ type: "confirm", gen: runner.state.gen,
            id: runner.state.approval.id, digest: runner.state.approval.digest, source: "key", ...extra });
        const refusal = () => JSON.parse(results.at(-1).results[0].item.content);
        // These ports acquire no resource. A defective reducer can leave an
        // invalid hold; only the fixture's real audit writer needs release.
        cleanups.push(() => audit.close());
        return { runner, router, audit, directory, rows, starts, answers, results, records,
            call, show, confirm, dispatch, refusal, newTurn,
            tick: value => {
                at = value;
                const due = [...timers].find(([, timer]) => timer.deadline <= at);
                assert.ok(due, "the runner owns the due deadline");
                timers.delete(due[0]);
                due[1].fn();
            },
            time: value => { at = value; }, lock: value => { locked = value; }, target: value => { target = value; } };
    }
    const shell = { argv: ["fixture"], cwd: fixtures.project, network: false };
    const text = { text: "fixture text" };
    const held = w => { assert.equal(w.call("shell.argv", shell).kind, "held"); w.show(); w.time(700); };
    const cases = [
        ["allow", implementation => {
            const w = make(implementation);
            assert.equal(w.call("windows.list").kind, "proposed");
            assert.equal(w.starts.length, 1);
            assert.equal(w.records[0].decision, "allow");
            assert.equal(w.records[0].outcome, "pending", "audit exists when the real start callback runs");
            w.answers[0]({ outcome: "completed", content: "fixture windows" });
            assert.equal(w.runner.state.action.kind, "none");
            assert.equal(w.rows().at(-1).outcome, "completed");
            assert.equal(w.results.at(-1).results[0].id, "model-windows.list");
        }],
        ["refuse", implementation => {
            const w = make(implementation); w.lock(true);
            assert.equal(w.call("windows.list").reason, "session-locked");
            assert.equal(w.starts.length, 0);
            assert.equal(w.rows().at(-1).decision, "refuse");
            assert.equal(w.rows().at(-1).outcome, "cancelled");
            assert.deepEqual(w.refusal(), { kind: "refuse", reason: "session-locked" });
        }],
        ["hold", implementation => {
            const w = make(implementation); held(w);
            assert.equal(w.starts.length, 0);
            assert.equal(w.runner.state.approval.physical, false);
            assert.equal(w.rows().at(-1).decision, "confirm");
            assert.equal(w.rows().at(-1).outcome, "pending");
            assert.equal(w.results.length, 0, "holding is not a completed brain result");
        }],
        ["serial", (implementation, session = Session) => {
            const w = make(implementation, session); held(w);
            assert.equal(w.call("windows.list").reason, "busy");
            assert.equal(w.starts.length, 0, "nothing can start while held");
            assert.equal(w.refusal().reason, "busy");
            w.confirm();
            assert.equal(w.starts.length, 1);
            assert.equal(w.call("windows.list").reason, "busy");
            assert.equal(w.starts.length, 1, "a running tool also retains the slot");
        }],
        ["immutable-digest", implementation => {
            const w = make(implementation);
            const args = { network: false, cwd: fixtures.project, argv: ["fixture"] };
            const h = w.call("shell.argv", args);
            const crypto = require("node:crypto");
            const expected = crypto.createHash("sha256").update("shell.argv\n" +
                '{"argv":["fixture"],"cwd":' + JSON.stringify(fixtures.project) + ',"network":false}').digest("hex");
            assert.equal(h.digest, expected);
            args.argv[0] = "changed";
            w.show(); w.time(700); w.confirm();
            assert.deepEqual(w.starts[0].args.argv, ["fixture"]);
            assert.equal(Object.isFrozen(w.starts[0].args.argv), true);
            const second = make(implementation);
            const same = second.call("shell.argv", shell);
            assert.equal(same.digest, expected);
            assert.notEqual(same.id, h.id);
            for (const args of [{ command: "fill", args: { text: "literal", ref: "@e1" } },
                { args: { ref: "@e1", text: "literal" }, command: "fill" }]) {
                const browser = make(implementation);
                browser.target({ kind: "site", id: "example.test", password: false });
                assert.equal(browser.call("browser", args).digest,
                    crypto.createHash("sha256").update('browser\n{"args":{"ref":"@e1","text":"literal"},"command":"fill"}').digest("hex"));
            }
        }],
        ["typed-sentence", implementation => {
            const w = make(implementation, Session, { profile: "trusted" });
            w.target({ kind: "terminal", id: "terminal" });
            const exact = "printf '{text}'\nfixture only";
            w.call("input.text", { text: exact });
            assert.equal(w.runner.state.approval.text, "Type this exact text:\n" + exact);
            assert.equal(w.runner.state.approval.physical, true);
        }],
        ["approval-size", implementation => {
            const w = make(implementation, Session, { profile: "trusted" });
            w.target({ kind: "terminal", id: "terminal" });
            const label = "Type this exact text:\n";
            const textAtBound = "x".repeat(16384 - Buffer.byteLength(label));
            assert.equal(w.call("input.text", { text: textAtBound }).kind, "held");
            assert.equal(Buffer.byteLength(w.runner.state.approval.text), 16384);
            w.dispatch({ type: "cancel" }); w.newTurn();
            assert.equal(w.call("input.text", { text: textAtBound + "x" }).reason, "approval-size");
            assert.equal(w.starts.length, 0);
        }],
        ["result-size", implementation => {
            for (const [name, content, clipped] of [
                ["at-bound", "x".repeat(16384), false],
                ["past-bound", "x".repeat(16385), true],
                ["unicode-past-bound", "語".repeat(5462), true]
            ]) {
                const w = make(implementation);
                w.call("windows.list");
                w.answers[0]({ outcome: "completed", content });
                const delivered = w.results.at(-1).results[0].item.content;
                assert.ok(Buffer.byteLength(delivered) <= 16384, name);
                assert.equal(delivered.endsWith("\n[result clipped]"), clipped, name);
                assert.equal(delivered.includes("\ufffd"), false, "valid text stays valid at a byte cut");
                if (!clipped) assert.equal(delivered, content, "the accepted boundary stays unchanged");
            }
        }],
        ["unavailable-executor", implementation => {
            const w = make(implementation);
            let answer;
            assert.doesNotThrow(() => { answer = w.call("media.play"); }, "an unavailable tool returns a refusal");
            assert.equal(answer.reason, "executor-unavailable");
            assert.equal(w.refusal().reason, "executor-unavailable");
            assert.equal(w.rows().at(-1).decision, "refuse");
            assert.equal(w.starts.length, 0);
        }],
        ...[
            ["synthetic-id", { id: "11111111-1111-4111-8111-111111111111" }],
            ["forged-digest", { digest: "0".repeat(64) }],
            ["stale-generation", { gen: 999 }],
            ["synthetic-source", { source: "model" }]
        ].map(([name, extra]) => [name, (implementation, session = Session) => {
            const w = make(implementation, session); held(w); w.confirm(extra);
            assert.equal(w.starts.length, 0, name);
            assert.equal(w.runner.state.approval.kind, "held");
            assert.equal(w.rows().at(-1).decision, "refuse");
        }]),
        ["model-confirm", implementation => {
            const w = make(implementation);
            assert.equal(w.call("confirm_last").reason, "unknown-tool");
            assert.equal(w.call("confirm", {}).reason, "unknown-tool");
            assert.equal(Object.hasOwn(w.router, "confirm"), false);
            assert.equal(w.starts.length, 0);
        }],
        ["early", (implementation, session = Session) => {
            for (const drawn of [false, true]) {
                const w = make(implementation, session);
                w.call("shell.argv", shell);
                if (drawn) w.show();
                w.time(drawn ? 699 : 700);
                w.confirm();
                assert.equal(w.starts.length, 0);
                assert.equal(w.rows().at(-1).decision, "refuse");
            }
        }],
        ["expired", (implementation, session = Session) => {
            const w = make(implementation, session); held(w);
            // A brain may end its response while the approval remains on screen.
            w.dispatch({ type: "brain-done", ...w.runner.state.turn });
            w.time(60000); w.confirm();
            assert.equal(w.starts.length, 0);
            assert.equal(w.runner.state.approval.kind, "none");
            assert.equal(w.rows().at(-1).decision, "refuse");
        }],
        ...["deadline", "confirm"].map(entry => ["thinking-" + entry + "-approval", (implementation, session = Session) => {
            for (const acknowledged of [false, true]) {
                const w = make(implementation, session, { profile: "cautious", ackCancel: acknowledged });
                assert.equal(w.runner.state.turn.deadline, 60000);
                w.time(10000);
                const approval = w.call("windows.close", { window: "0x123" });
                assert.equal(approval.kind, "held");
                assert.equal(w.runner.state.approval.deadline, 70000);
                w.show();
                w.time(59999);
                w.dispatch({ type: "deadline", gen: w.runner.state.turn.gen, op: w.runner.state.turn.op });
                assert.equal(w.runner.state.approval.kind, "held", "hold survives before the thinking deadline");
                assert.equal(w.runner.state.turn.kind, "thinking");
                const identity = { id: approval.id, digest: approval.digest, gen: w.runner.state.gen };
                if (entry === "deadline") w.tick(60000);
                else { w.time(60000); w.confirm(identity); }
                w.confirm(identity);
                assert.equal(w.starts.length, 0, entry + " expiry cannot start the executor");
                assert.equal(w.runner.state.fault.reason, "thinking-timeout");
                assert.equal(w.runner.state.turn.kind, acknowledged ? "none" : "cancelling");
                assert.equal(w.runner.state.approval.kind, "none");
                assert.equal(w.refusal().reason, "thinking-timeout");
                assert.equal(w.rows().some(row => row.tool === "windows.close"
                    && row.decision === "refuse" && row.outcome === "cancelled"), true);
                assert.equal(w.runner.state.action.kind, "none");
                assert.equal(w.rows().at(-1).decision, "refuse");
            }
        }]),
        ["replay", (implementation, session = Session) => {
            const w = make(implementation, session); held(w);
            const approval = w.runner.state.approval;
            w.confirm();
            assert.equal(w.starts.length, 1);
            assert.equal(w.runner.state.approval.kind, "none");
            w.answers[0]({ outcome: "completed", content: "once" });
            w.confirm({ id: approval.id, digest: approval.digest });
            assert.equal(w.starts.length, 1);
            assert.equal(w.rows().at(-1).decision, "refuse");
            assert.equal(w.runner.state.action.kind, "none");
        }],
        ["replaced", (implementation, session = Session) => {
            const w = make(implementation, session); held(w);
            const approval = w.runner.state.approval;
            w.dispatch({ type: "interrupt" });
            w.newTurn();
            const fresh = w.call("shell.argv", shell);
            w.show(); w.time(1400);
            w.confirm({ id: approval.id, digest: approval.digest, gen: approval.gen });
            assert.equal(w.starts.length, 0);
            assert.equal(w.runner.state.approval.id, fresh.id);
            w.confirm();
            assert.equal(w.starts.length, 1);
        }],
        ["voice-physical", (implementation, session = Session) => {
            const w = make(implementation, session, { profile: "trusted" });
            w.target({ kind: "terminal", id: "terminal" });
            w.call("input.text", text); w.show(); w.time(700);
            w.confirm({ source: "voice" });
            assert.equal(w.starts.length, 0);
            w.confirm({ source: "button" });
            assert.equal(w.starts.length, 1);
            assert.equal(w.records[0].confirmed, "physical");
            const nonphysical = make(implementation); held(nonphysical);
            nonphysical.confirm({ source: "voice" });
            assert.equal(nonphysical.starts.length, 1);
            assert.equal(nonphysical.records[0].confirmed, "voice");
        }],
        ["rejudge", implementation => {
            const w = make(implementation); held(w); w.lock(true); w.confirm();
            assert.equal(w.starts.length, 0);
            assert.equal(w.refusal().reason, "session-locked");
            assert.equal(w.runner.state.action.kind, "none");
            const file = path.join(fixtures.project, "moved");
            fs.writeFileSync(file, "fixture");
            const changed = make(implementation);
            changed.call("files.delete", { path: file }); changed.show(); changed.time(700);
            fs.unlinkSync(file);
            fs.mkdirSync(path.join(fixtures.home, ".ssh"), { recursive: true });
            fs.symlinkSync(path.join(fixtures.home, ".ssh"), file);
            changed.confirm();
            assert.equal(changed.starts.length, 0);
            assert.equal(changed.refusal().reason, "protected-path");
            fs.unlinkSync(file);
        }],
        ["target-rejudge", implementation => {
            const w = make(implementation);
            w.call("input.text", text); w.show(); w.time(700);
            w.target({ kind: "application", id: "other" }); w.confirm();
            assert.equal(w.starts.length, 0);
            assert.equal(w.refusal().reason, "policy-changed");
        }],
        ["audit-before", implementation => {
            for (const scoped of [false, true]) {
                const w = make(implementation);
                if (scoped) { w.call("input.text", text); w.show(); w.time(700); }
                else held(w);
                // An existing non-directory audit path makes the real writer refuse.
                fs.rmSync(path.join(w.directory, "audit"), { recursive: true });
                fs.writeFileSync(path.join(w.directory, "audit"), "blocked");
                w.confirm();
                assert.equal(w.starts.length, 0);
                assert.equal(w.refusal().reason, "audit-write");
                assert.equal(w.runner.state.action.kind, "none");
                if (scoped) {
                    fs.unlinkSync(path.join(w.directory, "audit"));
                    assert.equal(w.call("input.text", text).kind, "held", "failed audit cannot issue a scope");
                    fs.rmSync(path.join(w.directory, "audit"), { recursive: true });
                    fs.writeFileSync(path.join(w.directory, "audit"), "blocked");
                }
                w.runner.close();
                assert.equal(w.runner.lifetime.kind, "closed", "teardown cannot depend on a writable audit");
            }
        }],
        ["audit-refusal", implementation => {
            const w = make(implementation);
            fs.writeFileSync(path.join(w.directory, "audit"), "blocked");
            assert.throws(() => w.confirm({ id: "synthetic", digest: "0".repeat(64) }),
                { message: "jarvis: audit=write cause=directory-type" });
            assert.equal(w.starts.length, 0);
            w.runner.close();
        }],
        ["grants", implementation => {
            const first = make(implementation);
            first.call("input.text", text); first.show(); first.time(700);
            first.confirm({ digest: "f".repeat(64) });
            assert.equal(first.starts.length, 0);
            first.confirm();
            assert.equal(first.starts.length, 1);
            first.answers[0]({ outcome: "completed", content: "typed" });
            assert.equal(first.call("input.text", text).kind, "proposed");
            assert.equal(first.starts.length, 2);
            first.answers[1]({ outcome: "completed", content: "typed twice" });
            const second = make(implementation);
            assert.equal(second.call("input.text", text).kind, "held", "a new router cannot inherit a grant");
            first.dispatch({ type: "stop" }); first.newTurn();
            assert.equal(first.call("input.text", text).kind, "held", "a new conversation cannot inherit a grant");
        }],
        ["grant-bound", implementation => {
            const w = make(implementation);
            for (let n = 0; n < 64; n++) {
                w.target({ kind: "application", id: "fixture-" + n });
                assert.equal(w.call("input.text", text).kind, "held");
                w.show(); w.time((n + 1) * 700); w.confirm();
                assert.equal(w.starts.length, n + 1);
                w.answers[n]({ outcome: "completed", content: "typed" });
            }
            w.target({ kind: "application", id: "past-bound" });
            assert.equal(w.call("input.text", text).reason, "grant-limit");
            assert.equal(w.starts.length, 64);
            w.target({ kind: "application", id: "fixture-0" });
            assert.equal(w.call("input.text", text).kind, "proposed", "existing grants stay usable at the bound");
        }],
        ["taint", implementation => {
            const w = make(implementation);
            w.call("files.read", { path: path.join(fixtures.project, "existing") });
            w.answers[0]({ outcome: "completed", content: "untrusted file" });
            assert.deepEqual(w.results.at(-1).results[0].item.labels, ["file"]);
            assert.equal(w.call("files.write", { path: path.join(fixtures.project, "new"), text: "write" }).kind, "held");
            w.dispatch({ type: "cancel" });
            w.newTurn();
            assert.equal(w.call("files.write", { path: path.join(fixtures.project, "new"), text: "write" }).kind, "proposed");
        }],
        ["stale-turn", implementation => {
            const w = make(implementation);
            const old = w.runner.state.turn;
            w.dispatch({ type: "stop" }); w.newTurn();
            assert.equal(w.call("windows.list", {}, old).reason, "stale-turn");
            assert.equal(w.starts.length, 0);
        }],
        ["outcome-lifetime", implementation => {
            for (const outcome of ["completed", "failed", "unknown"]) {
                const w = make(implementation);
                const old = w.runner.state.turn;
                w.call("windows.list");
                w.dispatch({ type: "stop" });
                w.answers[0]({ outcome, content: "fixture result" });
                assert.equal(w.rows().at(-1).outcome, outcome);
                assert.equal(w.rows().at(-1).gen, old.gen);
                assert.equal(w.results.at(-1).op, old.op);
                assert.equal(w.results.at(-1).outcome, outcome);
                const before = w.results.length;
                w.answers[0]({ outcome: "completed", content: "replayed callback" });
                assert.equal(w.results.length, before);
            }
        }],
        ["timeout-and-cleanup", implementation => {
            const w = make(implementation);
            w.call("windows.list");
            w.time(1000);
            w.dispatch({ type: "deadline", gen: w.runner.state.action.gen, op: w.runner.state.action.op });
            assert.equal(w.results.at(-1).outcome, "unknown");
            assert.equal(w.call("windows.list").reason, "busy");
            w.answers[0]({ outcome: "completed", content: "late result" });
            assert.equal(w.rows().at(-1).outcome, "completed");
            assert.equal(w.call("windows.list").kind, "proposed");
            w.runner.close(); w.audit.close();
            const before = w.results.length;
            w.answers[1]({ outcome: "completed", content: "after lease" });
            assert.equal(w.results.length, before);
            assert.deepEqual(w.router.offer(), []);
        }],
        ["offer", implementation => {
            const w = make(implementation);
            assert.equal(w.router.offer().some(row => row.id === "windows.list"), true);
            assert.equal(w.router.offer().some(row => row.id === "media.play"), false);
            assert.equal(w.router.offer().some(row => row.id === "files.read"), true);
            const noExecutors = implementation.create({ session: Session, state: () => w.runner.state,
                dispatch: () => {}, context: () => ({}), audit: w.audit, result: () => {} });
            assert.deepEqual(noExecutors.offer(), []);
            noExecutors.register("input", { commands: [], timeoutMs: 10, cancellable: false, start() {} });
            assert.deepEqual(noExecutors.offer(), [], "missing commands remove their tools");
        }],
        ["input-observer", implementation => {
            const w = make(implementation);
            const router = implementation.create({ session: Session, state: () => w.runner.state,
                dispatch: () => {}, context: () => ({ profile: "standard", locked: false }),
                audit: w.audit, result: value => w.results.push(value) });
            router.register("input", { commands: ["wtype"], timeoutMs: 10, cancellable: false, start() {} });
            assert.equal(router.route({ id: "model", tool: "input.text", arguments: text },
                { gen: w.runner.state.turn.gen, op: w.runner.state.turn.op }).reason, "input-target");
        }]
    ];
    try {
        for (const [name, check] of cases) { check(Router); console.log("case=" + name + " passed"); }
        const byName = name => cases.find(row => row[0] === name)[1];
        const controlsTable = [
            ["rejudge", "const fresh = judge(value);", "const fresh = value.decision;", "rejudge"],
            ["audit-before", "const admitted = audit.before(", "const admitted = ({ before: (event, start) => ({ kind: 'started', value: start() }) }).before(", "audit-before"],
            ["audit-refusal", 'throw new Error("jarvis: audit=write cause=" + written.cause);',
                'void written.cause;', "audit-refusal"],
            ["turn-identity", "s.gen !== turn.gen || s.turn.kind !== \"thinking\" || s.turn.gen !== turn.gen || s.turn.op !== turn.op",
                "false", "stale-turn"],
            ["observe", "taint = Policy.observe(taint, source);", "void source;", "taint"],
            ["reset-turn", 'taint = { kind: "clean" };\n        }', 'void turnOp;\n        }', "taint"],
            ["outcomes", "record(value, value.decision.kind, e.outcome)", 'record(value, value.decision.kind, "unknown")', "outcome-lifetime"],
            ["grants", "grants.add(prior.scope);", "void prior.scope;", "grants"],
            ["grant-bound", "grants.size >= GRANT_SCOPES", "(false && grants.size >= GRANT_SCOPES)", "grant-bound"],
            ["target-rejudge", "fresh.scope === prior.scope", "(true || fresh.scope === prior.scope)", "target-rejudge"],
            ["digest", 'value.call.id + "\\n" + canonical(value.call.args)', 'value.call.id + "\\n" + "{}"', "immutable-digest"],
            ["sentence", 'sentence(value.call, decision.scope)', '"model text"', "typed-sentence"],
            ["approval-size", "Buffer.byteLength(text) > RESULT_BYTES", "false", "approval-size"],
            ["result-size", "bytes.length <= RESULT_BYTES", "true", "result-size"],
            ["unavailable-executor", 'if (value.executor === null) return refuse(value, "executor-unavailable");',
                'if (false) return refuse(value, "executor-unavailable");', "unavailable-executor"],
            ["command-offer", "refined.command === null || executor.commands.includes(refined.command)",
                "true", "offer"]
        ];
        for (const [name, needle, replacement, row] of controlsTable) {
            mutant(routerFile, name, needle, replacement, byName(row));
            controls++; console.log("control=" + name + " detected");
        }
        for (const [name, needle, replacement, row] of [
            ["digest-binding", "e.digest !== approval.digest", "(false && e.digest !== approval.digest)", "forged-digest"],
            ["id-binding", "e.id !== approval.id", "(false && e.id !== approval.id)", "synthetic-id"],
            ["draw-ack", ": approval.shownAt === null ||", ": (false && approval.shownAt === null) ||", "early"],
            ["draw-delay", "e.at - approval.shownAt < APPROVAL_DRAW_MS", "(false && e.at - approval.shownAt < APPROVAL_DRAW_MS)", "early"],
            ["voice-physical", 'e.source === "voice" && approval.physical', "false", "voice-physical"],
            ["accepted-once", 's.approval = { kind: "none" };\n        var accepted', 's.approval = approval;\n        var accepted', "replay"]
        ]) {
            qmlCopy(sessionFile, [[needle, replacement]], session =>
                assert.throws(() => byName(row)(Router, session), assert.AssertionError, name + " must turn red"));
            controls++; console.log("control=" + name + " detected");
        }
        qmlCopy(sessionFile, [
            ['s.approval.kind === "held" && at >= s.approval.deadline', 'false && s.approval.kind === "held" && at >= s.approval.deadline']
        ], session => assert.throws(() => byName("expired")(Router, session), assert.AssertionError));
        controls++; console.log("control=deadline detected");
        for (const [name, needle, replacement, row] of [
            ["thinking-retirement", 'dropApproval(s, effects, "thinking-timeout");',
                'if (false) dropApproval(s, effects, "thinking-timeout");', "thinking-deadline-approval"],
            ["delayed-thinking-expiry", 'if (e.type !== "deadline") expire(s, effects, e.at);',
                'if (false && e.type !== "deadline") expire(s, effects, e.at);', "thinking-confirm-approval"]
        ]) {
            qmlCopy(sessionFile, [[needle, replacement]], session =>
                assert.throws(() => byName(row)(Router, session), assert.AssertionError, name + " must turn red"));
            controls++; console.log("control=" + name + " detected");
        }
        qmlCopy(sessionFile, [['if (!canPropose(s)) break;', 'if (false) break;', 2]], session =>
            mutant(routerFile, "serial", "!session.canPropose(s) || pending !== null", "false",
                implementation => byName("serial")(implementation, session)));
        controls++; console.log("control=serial detected");
        mutant(routerFile, "grant-leak", [
            ["const RESULT_BYTES = 16 * 1024;", "const RESULT_BYTES = 16 * 1024;\nconst sharedGrants = new Set();"],
            ["let grants = new Set();", "let grants = sharedGrants;"],
            ["grants = new Set();", "grants = sharedGrants;"]
        ], null, byName("grants"));
        controls++;
        console.log("control=grant-leak detected");
        console.log("test-jarvis-router: ok cases=" + cases.length + " controls=" + controls);
    } finally { for (const cleanup of cleanups.reverse()) cleanup(); }
});
