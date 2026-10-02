#!/usr/bin/env node
// Real shell tools, router, reducer, audit and bwrap in J09 scratch namespaces.
// Forbidden cases come from the plan's shared synthetic list, 2026-09-30.
// No authentication program, live endpoint, device or external network runs.
"use strict";
const { assert, fs, path, tree, world, seed, pluginCopy } = require("./fixtures/jarvis/policy.js");
const { cases } = require("./fixtures/jarvis/forbidden.js");
const { load } = require("../bin/lib/qml-library.js");
const backend = path.join(tree, "shell/plugins/vgs.jarvis/backend");
const Shell = require(path.join(backend, "Shell.js"));
const Sandbox = require(path.join(backend, "Sandbox.js"));
const Router = require(path.join(backend, "ToolRouter.js"));
const Denied = require(path.join(backend, "Denied.js"));
const Audit = require(path.join(backend, "Audit.js"));
const { SessionRunner, unavailable } = require(path.join(backend, "session-runner.js"));
const Session = load(path.join(backend, "../Session.js"));
const node = "/usr/bin/node";
const js = code => [node, "-e", code];

world(async () => {
    for (const command of ["sudo", "pkexec", "doas", "run0", "su", "faillock", "secret-tool"])
        for (const directory of process.env.PATH.split(":"))
            assert.equal(fs.existsSync(path.join(directory, command)), false, "no host auth fallback: " + command);
    const w = seed();
    for (const row of cases(w).filter(row => row.file)) {
        fs.mkdirSync(path.dirname(row.file), { recursive: true });
        fs.writeFileSync(row.file, "synthetic protected content");
    }
    fs.mkdirSync(w.home + "/.claude-personal");
    fs.mkdirSync(w.home + "/hand-added");
    fs.mkdirSync(w.roots.state + "/vgs/jarvis", { recursive: true });
    fs.writeFileSync(w.roots.state + "/vgs/jarvis/accounts.json", JSON.stringify([
        { provider: "codex", directory: w.home + "/hand-added", label: "Fixture" }
    ]));
    const trusted = Shell.roots(process.env, { state: w.roots.state + "/vgs/jarvis" }, w.roots.install);
    assert.ok(trusted().accountRoots.includes(w.home + "/.claude-personal"));
    assert.ok(trusted().accountRoots.includes(w.home + "/hand-added"));

    const available = await Sandbox.available();
    if (available.kind !== "available") {
        console.log("test-jarvis-shell: not-verified=" + JSON.stringify(available));
        process.exitCode = 77;
        return;
    }
    const cleanups = [];
    function make(implementation = Shell, options = {}) {
        let at = 0, locked = false, transcript, waiting;
        const results = [], statuses = [], deadlines = new Map();
        const audit = Audit.create({ state: fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "shell-audit-")) });
        const ports = { ...unavailable(), mute: { store() {} },
            capture: { open: (_e, done) => done(), close: (_e, done) => done(), collect: (_e, done) => { transcript = done; } },
            brain: { send() {}, cancel: (_e, done) => done(), close() {}, outcome() {} } };
        const runner = new SessionRunner(Session, ports, { now: () => at,
            set: () => ({}), clear() {} }, () => {});
        const router = Router.create({ session: Session, state: () => runner.state,
            dispatch: e => runner.dispatch(e), context: () => ({ profile: options.profile ?? "trusted", locked,
                denied: options.roots === undefined ? Denied.create(trusted()) : null }), audit,
            result: value => { results.push(value); if (waiting) { const wake = waiting; waiting = null; wake(value); } } });
        Object.assign(ports, router.ports);
        const shell = implementation.install({ router, roots: options.roots ?? trusted,
            status: value => statuses.push(value), failed: error => { throw error; },
            clock: { set: (fn, ms) => { const key = {}; deadlines.set(key, { fn, ms }); return key; },
                clear: key => deadlines.delete(key) } });
        runner.dispatch({ type: "snapshot", locked: false, engine: "chained", configured: true, settings: {} });
        runner.dispatch({ type: "indicator", shown: true });
        const turn = () => { runner.dispatch({ type: "talk-down" }); transcript("final", "synthetic user"); };
        turn();
        function call(id, args) {
            return router.route({ kind: "tool-call", id: "fixture", tool: id, arguments: args },
                { gen: runner.state.turn.gen, op: runner.state.turn.op });
        }
        const next = () => new Promise(resolve => { waiting = resolve; });
        async function run(id, args) {
            // Each command is its own user turn. Command output retains its
            // source; it cannot become speech or desktop metadata.
            if (results.length) turn();
            const done = next();
            const proposal = call(id, args);
            if (proposal.kind === "held") {
                runner.dispatch({ type: "shown", gen: runner.state.gen,
                    op: runner.state.approval.op, id: proposal.id });
                at += 700;
                runner.dispatch({ type: "confirm", gen: runner.state.gen,
                    id: proposal.id, digest: proposal.digest, source: "key" });
            }
            const value = await done;
            const content = value.results[0].item.content;
            const parts = content.split("\n");
            const answer = JSON.parse(parts[0]);
            if (parts.length > 1 && !content.endsWith("[result clipped]")) Object.assign(answer, JSON.parse(parts[1]));
            return { proposal, value, answer };
        }
        const close = () => {
            shell.close(); runner.close();
            // A detected cancellation mutant still owns a scratch child.
            // Fire its real deadline only after its lifetime assertion failed.
            for (const deadline of [...deadlines.values()]) deadline.fn();
            audit.close();
        };
        cleanups.push(close);
        return { shell, router, runner, statuses, results, call, run, next, deadlines,
            lock: value => { locked = value; }, turn, close };
    }

    const a = { argv: ["pwd"], cwd: w.project, network: false };
    async function offered(implementation) {
        const h = make(implementation);
        assert.equal(h.router.offer().some(row => row.id === "shell.argv"), false, "no offer before probe");
        await h.shell.ready;
        assert.deepEqual(h.statuses, [{ kind: "checking" }, { kind: "available" }]);
        assert.deepEqual(h.router.offer().filter(row => row.id.startsWith("shell.")).map(row => row.id), ["shell.argv", "shell.line"]);
        h.shell.close();
        assert.equal(h.router.offer().some(row => row.id.startsWith("shell.")), false, "closed lease withdraws offers");
        h.close();
    }
    await offered(Shell);
    const h = make(); await h.shell.ready;
    const pwd = await h.run("shell.argv", a);
    assert.equal(pwd.proposal.kind, "proposed");
    assert.equal(pwd.value.outcome, "completed");
    assert.deepEqual(pwd.answer, { kind: "exited", code: 0, stdout: w.project + "\n", stderr: "" });
    assert.deepEqual(pwd.value.results[0].item.labels, ["command"]);
    console.log("case=help");
    const help = h.next(); h.turn();
    assert.equal(h.call("help", { topic: "shell" }).kind, "proposed");
    assert.equal((await help).results[0].item.content,
        fs.readFileSync(path.join(backend, "skills/computer/shell.md"), "utf8").trim());
    console.log("case=line");
    const line = await h.run("shell.line", { cwd: w.project, network: false,
        line: "printf '%s' 'quoted value'; printf '%s' 'stderr value' >&2" });
    assert.equal(line.proposal.kind, "proposed");
    assert.deepEqual(line.answer, { kind: "exited", code: 0, stdout: "quoted value", stderr: "stderr value" });
    for (const [code, outcome] of [[1, "failed"], [77, "failed"]]) {
        const result = await h.run("shell.argv", { ...a, argv: js("process.exit(" + code + ")") });
        assert.equal(result.answer.kind, "exited"); assert.equal(result.answer.code, code);
        assert.equal(result.value.outcome, outcome);
    }
    // Direct elevation and lock calls reach the real router and never spawn
    // authentication. Protected-file cases then reach the actual executor.
    console.log("case=forbidden");
    for (const profile of ["cautious", "standard", "trusted"]) {
        const f = make(Shell, { profile }); await f.shell.ready;
        for (const row of cases(w).filter(row => row.calls.some(call => call.id === "shell.argv"))) {
            for (const call of row.calls.filter(call => call.id === "shell.argv")) {
                f.lock(row.locked === true);
                assert.equal(f.call(call.id, call.args).reason, row.reason, profile + ": " + row.name);
                if (row.file) {
                    f.lock(false);
                    for (const operation of ["readFileSync", "writeFileSync"]) {
                        const code = "try { require('node:fs')." + operation + "(" + JSON.stringify(row.file)
                            + (operation === "writeFileSync" ? ", 'planted'" : "")
                            + "); process.exit(0); } catch (e) { process.exit(42); }";
                        const result = await f.run("shell.argv", { ...a, argv: js(code) });
                        assert.equal(result.answer.code, 42, profile + ": kernel " + row.name);
                        assert.equal(result.value.outcome, "failed");
                    }
                }
            }
        }
        f.close();
    }
    for (const account of [w.home + "/.claude-personal", w.home + "/hand-added"])
        assert.equal(Denied.create(trusted()).inspect(account, "read").reason, "protected-path");
    // Kernel authority replaces unsafe token scanning. Read its privilege
    // bit without invoking sudo, PAM or a keyring service.
    console.log("case=isolation");
    const isolation = await h.run("shell.line", { cwd: w.project, network: false,
        line: node + " -e " + "'" + "const f=require(\"node:fs\");process.stdout.write(JSON.stringify({priv:f.readFileSync(\"/proc/self/status\",\"utf8\").match(/NoNewPrivs:\\s*(\\d)/)[1],env:[\"WAYLAND_DISPLAY\",\"HYPRLAND_INSTANCE_SIGNATURE\",\"DBUS_SESSION_BUS_ADDRESS\",\"PIPEWIRE_REMOTE\"].map(k=>process.env[k]??null),dev:f.existsSync(\"/dev/uinput\")}))" + "'" });
    assert.deepEqual(JSON.parse(isolation.answer.stdout), { priv: "1", env: [null, null, null, null], dev: false });
    console.log("case=output");
    const overflow = await h.run("shell.argv", { ...a, argv: js("process.stdout.write('x'.repeat(65537))") });
    assert.equal(overflow.value.outcome, "unknown");
    assert.equal(overflow.answer.kind, "stopped");
    assert.equal(overflow.answer.reason, "output-limit");
    assert.ok(Buffer.byteLength(overflow.value.results[0].item.content) <= 16384);
    assert.match(overflow.value.results[0].item.content, /\[result clipped\]$/);
    for (const [stdout, stderr, outcome, kind] of [
        [65536, 0, "completed", "exited"], [32768, 32769, "unknown", "stopped"]
    ]) {
        const output = await h.run("shell.argv", { ...a, argv: js("process.stdout.write('x'.repeat(" + stdout
            + "));process.stderr.write('e'.repeat(" + stderr + "))") });
        assert.equal(output.value.outcome, outcome);
        assert.equal(output.answer.kind, kind);
    }

    // The actual production deadline is injected, not shortened. Wait only
    // for the scratch child to announce its acquisition, then fire it.
    const { until } = require("./fixtures/jarvis/audio.js");
    h.close();
    async function timeout(s) {
        const f = make(s); await f.shell.ready;
        const marker = fs.mkdtempSync(path.join(w.project, "deadline-")) + "/started";
        const done = f.next();
        // Natural completion bounds the removed-timeout control. The test
        // fires Sandbox's clock as soon as the child announces acquisition.
        assert.equal(f.call("shell.argv", { ...a, argv: js("require('node:fs').writeFileSync(" + JSON.stringify(marker)
            + ", 'ready');setTimeout(()=>{},500)") }).kind, "proposed");
        await until(() => fs.existsSync(marker), "sandbox child started");
        assert.equal(f.deadlines.size, 1);
        const deadline = [...f.deadlines.values()][0];
        assert.equal(deadline.ms, 120000); deadline.fn();
        const timed = await done;
        assert.equal(timed.outcome, "unknown");
        assert.equal(JSON.parse(timed.results[0].item.content.split("\n")[0]).reason, "timeout");
        assert.equal(f.runner.state.action.kind, "none");
        f.close();
    }
    console.log("case=timeout");
    await timeout(Shell);

    const cp = require("node:child_process");
    fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis/sandbox-child.py"), w.project + "/child.py");
    async function teardown(s, mode) {
        const f = make(s); await f.shell.ready;
        const folder = fs.mkdtempSync(path.join(w.project, "lifetime-"));
        const lock = folder + "/lock", marker = folder + "/ready";
        const done = f.next();
        assert.equal(f.call("shell.argv", { ...a, argv: ["/usr/bin/python3", "-I", w.project + "/child.py", lock, marker] }).kind, "proposed");
        await until(() => fs.existsSync(marker), "scratch descendant owns its lock");
        await f.shell.refresh();
        if (mode === "cancel") {
            f.runner.dispatch({ type: "stop" });
        } else f.shell.close();
        // Wait for only the owned scratch lock to be released. This also
        // reaches descendants that detached into a separate session.
        const probe = () => cp.spawnSync("/usr/bin/python3", ["-I", "-c",
            "import fcntl,sys\nwith open(sys.argv[1],'w') as f: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)", lock],
        { env: { PATH: "/usr/bin:/bin", LANG: "C.UTF-8" }, encoding: "utf8", timeout: 5000 });
        await until(() => probe().status === 0, "closed shell namespace releases descendant lock");
        await until(() => f.deadlines.size === 0, "sandbox child close releases its deadline");
        assert.equal(f.deadlines.size, 0);
        if (mode === "cancel") {
            const result = await done;
            assert.equal(result.outcome, "unknown");
            assert.equal(JSON.parse(result.results[0].item.content.split("\n")[0]).reason, "cancelled");
        }
        f.close();
    }
    console.log("case=cancel");
    await teardown(Shell, "cancel");
    console.log("case=close");
    await teardown(Shell, "close");

    // Private runtime copies preserve the production call and remove one
    // behavior. A loading or execution failure is never a detected control.
    async function control(name, file, edits, check) {
        await pluginCopy(path.join(backend, file), edits, async root =>
            assert.rejects(() => check(require(path.join(root, "backend/Shell.js"))), assert.AssertionError, name + " turns red"));
        console.log("control=" + name + " detected");
    }
    await control("readiness", "Shell.js", [["router.register(\"sandbox\", executor); registered = true;", "void executor; registered = true;"]], offered);
    await control("closed-offers", "Shell.js", [["available: () => !closed && readiness.kind", "available: () => readiness.kind"]], offered);
    await control("line", "Shell.js", [["[\"/bin/sh\", \"-c\", call.args.line]", "[\"/bin/sh\", \"-c\", \"true\"]"]], async s => {
        const f = make(s); await f.shell.ready;
        assert.equal((await f.run("shell.line", { cwd: w.project, network: false, line: "printf exact" })).answer.stdout, "exact");
        f.close();
    });
    await control("failed-exit", "Shell.js", [["result.code === 0 ? \"completed\" : \"failed\"", "\"completed\""]], async s => {
        const f = make(s); await f.shell.ready;
        assert.equal((await f.run("shell.argv", { ...a, argv: js("process.exit(42)") })).value.outcome, "failed");
        f.close();
    });
    await control("stopped-outcome", "Shell.js", [["case \"stopped\": outcome = \"unknown\";", "case \"stopped\": outcome = \"completed\";"]], async s => {
        const f = make(s); await f.shell.ready;
        assert.equal((await f.run("shell.argv", { ...a, argv: js("process.stdout.write('x'.repeat(65537))") })).value.outcome, "unknown");
        f.close();
    });
    await control("cancel", "Shell.js", [["if (active !== null) active.abort();", "void active;"]], s => teardown(s, "cancel"));
    await control("close", "Shell.js", [["executor.cancel();", "void executor;"]], s => teardown(s, "close"));
    await control("timeout-tool", "Sandbox.js", [['end("timeout")', 'void child.stdin']], timeout);
    await control("output-tool", "Sandbox.js", [["const LIMIT = 64 * 1024;", "const LIMIT = 128 * 1024;"]], async s => {
        const f = make(s); await f.shell.ready;
        assert.equal((await f.run("shell.argv", { ...a, argv: js("process.stdout.write('x'.repeat(65537))") })).answer.reason, "output-limit");
        f.close();
    });
    async function absent(s) {
        const f = make(s, { roots: () => { throw new Error("synthetic unavailable roots"); } });
        await f.shell.ready;
        assert.deepEqual(f.statuses.at(-1), { kind: "unavailable", reason: "protected-roots" });
        assert.equal(f.router.offer().some(row => row.id.startsWith("shell.")), false);
        assert.equal(f.call("shell.argv", a).reason, "executor-unavailable");
        f.close();
    }
    await absent(Shell);
    await control("absent-offers", "Shell.js", [["case \"unavailable\": break;", "case \"unavailable\": result.kind = \"available\"; router.register(\"sandbox\", executor); break;"]], absent);
    // Missing bootstrap and aborted readiness reach Sandbox's real public
    // interface. No fixture invokes an authentication program or host device.
    await pluginCopy(path.join(backend, "Sandbox.js"), [["function executable() {", "function executable() { return null;\n"]], async root => {
        const f = make(require(path.join(root, "backend/Shell.js")));
        await f.shell.ready;
        assert.deepEqual(f.statuses.at(-1), { kind: "unavailable", reason: "bwrap-missing" });
        assert.equal(f.router.offer().some(row => row.id.startsWith("shell.")), false);
        assert.equal(f.call("shell.argv", a).reason, "executor-unavailable");
        f.close();
    });
    async function probeCancellation(implementation) {
        const f = make(implementation);
        f.shell.close();
        await f.shell.ready;
        assert.deepEqual(f.statuses, [{ kind: "checking" }]);
        assert.equal(f.router.offer().some(row => row.id.startsWith("shell.")), false);
        assert.equal(f.deadlines.size, 0);
        f.close();
    }
    await probeCancellation(Shell);
    async function readinessLifetime(edits, mustFail) {
        await pluginCopy(path.join(backend, "Shell.js"), edits, async root => {
            let aborted = false;
            require(path.join(root, "backend/Sandbox.js")).available = options => {
                options.signal.addEventListener("abort", () => { aborted = true; }, { once: true });
                return Promise.resolve({ kind: "available" });
            };
            const check = async () => {
                const f = make(require(path.join(root, "backend/Shell.js")));
                f.shell.close(); await f.shell.ready;
                assert.equal(aborted, true, "closed lease aborts the acquired readiness probe");
                assert.deepEqual(f.statuses, [{ kind: "checking" }]);
                assert.equal(f.router.offer().some(row => row.id.startsWith("shell.")), false);
                f.close();
            };
            if (mustFail) await assert.rejects(check, assert.AssertionError);
            else await check();
        });
    }
    await readinessLifetime([], false);
    await readinessLifetime([["if (probe !== null) probe.abort();\n        executor.cancel();", "void probe;\n        executor.cancel();"]], true);
    // Deferred probes reach the real owner and real router without starting
    // an installer. Superseded completions arrive deliberately out of order.
    async function rescans(edits, mustFail = false) {
        await pluginCopy(path.join(backend, "Shell.js"), edits, async root => {
            const probes = [];
            require(path.join(root, "backend/Sandbox.js")).available = options =>
                new Promise(resolve => probes.push({ options, resolve }));
            const check = async () => {
                const discovered = [];
                const added = w.home + "/.claude-rescan";
                fs.rmSync(added, { recursive: true, force: true });
                const f = make(require(path.join(root, "backend/Shell.js")), {
                    roots: () => { const value = trusted(); discovered.push(value); return value; }
                });
                // The frozen real router owns registration; its duplicate
                // guard makes the next successful refresh a behavioral check.
                probes[0].resolve({ kind: "unavailable", reason: "bwrap-missing" });
                await f.shell.ready;
                assert.equal(f.router.offer().some(row => row.id.startsWith("shell.")), false);
                assert.equal(discovered.length, 1);
                assert.equal(discovered[0].accountRoots.includes(added), false);
                fs.mkdirSync(added, { recursive: true });
                const recovered = f.shell.refresh();
                assert.equal(discovered.length, 2, "rescan rebuilds protected roots");
                assert.ok(discovered[1].accountRoots.includes(added), "new account metadata reaches current protected roots");
                probes[1].resolve({ kind: "available" }); await recovered;
                assert.deepEqual(f.router.offer().filter(row => row.id.startsWith("shell.")).map(row => row.id),
                    ["shell.argv", "shell.line"]);
                const repeated = f.shell.refresh();
                assert.equal(f.router.offer().some(row => row.id.startsWith("shell.")), false, "checking withdraws offers");
                const missing = f.shell.refresh();
                assert.equal(probes[2].options.signal.aborted, true, "new scan aborts superseded probe");
                probes[3].resolve({ kind: "unavailable", reason: "bwrap-missing" }); await missing;
                probes[2].resolve({ kind: "available" }); await repeated;
                assert.deepEqual(f.statuses.at(-1), { kind: "unavailable", reason: "bwrap-missing" }, "stale probe cannot recover readiness");
                assert.equal(f.router.offer().some(row => row.id.startsWith("shell.")), false);
                assert.equal(f.call("shell.argv", a).reason, "executor-unavailable");
                const again = f.shell.refresh(); probes[4].resolve({ kind: "available" }); await assert.doesNotReject(again);
                assert.equal(f.router.offer().filter(row => row.id.startsWith("shell.")).length, 2, "registration survives repeat success once");
                const closing = f.shell.refresh(); f.shell.close();
                assert.equal(probes[5].options.signal.aborted, true);
                const last = f.statuses.length;
                probes[5].resolve({ kind: "available" }); await closing;
                assert.equal(f.statuses.length, last, "closed lease suppresses late rescan");
                assert.equal(f.router.offer().some(row => row.id.startsWith("shell.")), false);
                f.close();
            };
            if (mustFail) await assert.rejects(check, assert.AssertionError);
            else await check();
        });
    }
    await rescans([]);
    for (const [name, needle, replacement] of [
        ["register-once", "if (!registered) { router.register", "if (true) { router.register"],
        ["fresh-roots", "Denied.create(currentRoots());", "void currentRoots;"],
        ["withdraw-offers", 'available: () => !closed && readiness.kind === "available"', 'available: () => !closed'],
        ["superseded-probe", "if (probe !== null) probe.abort();\n        const acquired", "void probe;\n        const acquired"],
        ["stale-probe", "if (closed || probe !== acquired) return;", "if (closed) return;"]
    ]) {
        await rescans([[needle, replacement]], true);
        console.log("control=rescan-" + name + " detected");
    }
    async function probeOptions(sandbox) {
        const controller = new AbortController(); controller.abort();
        const result = await sandbox.available({ signal: controller.signal });
        assert.equal(result.kind, "unavailable");
        assert.equal(result.detail.reason, "cancelled");
    }
    await probeOptions(Sandbox);
    await pluginCopy(path.join(backend, "Sandbox.js"), [["command(args, [\"/usr/bin/true\"]), options", "command(args, [\"/usr/bin/true\"])" ]], async root => {
        await assert.rejects(() => probeOptions(require(path.join(root, "backend/Sandbox.js"))), assert.AssertionError);
    });
    // Account enumeration remains in its existing owner. Both policy and
    // kernel commands consume the same fresh snapshot.
    for (const account of [w.home + "/.claude-personal", w.home + "/hand-added"]) {
        fs.writeFileSync(account + "/fixture", "synthetic credential");
        const f = make(); await f.shell.ready;
        const result = await f.run("shell.argv", { ...a, argv: js("try{require('node:fs').readFileSync(" + JSON.stringify(account + "/fixture") + ");process.exit(0)}catch{process.exit(42)}") });
        assert.equal(result.answer.code, 42);
        f.close();
    }
    for (const cleanup of cleanups) cleanup();
    console.log("test-jarvis-shell: ok forbidden=router-and-kernel timeout=120000 output=65536");
});
