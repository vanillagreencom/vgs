#!/usr/bin/env node
// The bounded child owner, Child.js, inside the J09 world. Fixtures are node
// scripts this suite writes; no desktop, audio, bus or network command runs.
// Each control edits a disposable copy of Child.js, one rule at a time.
"use strict";
const { assert, fs, path, tree, world, mutant } = require("./fixtures/jarvis/policy.js");
const childFile = path.join(tree, "shell/plugins/vgs.jarvis/backend/Child.js");

const alive = pid => {
    try { process.kill(pid, 0); return true; }
    catch (error) { if (error.code === "ESRCH") return false; throw error; }
};
const groupOf = pid => Number(fs.readFileSync("/proc/" + pid + "/stat", "utf8").split(") ").at(-1).split(" ")[2]);

world(() => {
    const root = fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "child-"));
    const env = { PATH: "/usr/bin:/bin", LC_ALL: "C.UTF-8", FIXTURE: "kept" };
    const node = process.execPath;
    const marker = name => path.join(root, name);
    // Fixture readiness, not a latency: each wait ends when the file appears.
    async function ready(file) {
        for (let i = 0; i < 1000 && !fs.existsSync(file); i++) await new Promise(resolve => setTimeout(resolve, 5));
        assert.ok(fs.existsSync(file), "fixture never wrote " + file);
        return Number(fs.readFileSync(file, "utf8"));
    }
    const onReady = file => ({ set(fn, ms) { assert.equal(ms, 5000); ready(file).then(fn); return file; }, clear() {} });
    // Only controls get this bound: a copy that never ends its child reaches
    // it in 2 s. Passing cases keep the 5 s deadline on the real clock, so no
    // assertion races a timer.
    const bounded = { set(fn, ms) { assert.equal(ms, 5000); return setTimeout(fn, 2000); }, clear: timer => clearTimeout(timer) };
    const base = { env, limit: 1024, deadline: 5000, group: true };
    const script = text => ["-e", text];
    // Forks a member of this group that outlives the leader. An inheriting
    // member holds its stdout and stderr, as a forked server may.
    const server = (name, inherit) => `const s=require("node:child_process").spawn(process.execPath,["-e","setInterval(()=>{},1000)"],`
        + `{stdio:${inherit ? '["ignore","inherit","inherit"]' : '"ignore"'}});`
        + `require("node:fs").writeFileSync(${JSON.stringify(marker(name))},String(s.pid));s.unref();`;
    const cleanup = [];
    const cases = [
        ["exited", async Child => {
            const result = await Child.run(node, script('process.stdout.write(JSON.stringify(process.env));process.stderr.write("e");process.exit(3)'), base);
            assert.equal(result.kind, "exited");
            assert.equal(result.code, 3);
            assert.equal(result.signal, null);
            assert.deepEqual(JSON.parse(result.stdout), env, "the child's environment is exactly the one given");
            assert.equal(result.stderr, "e");
        }],
        ["input", async Child => {
            const echo = script('process.stdout.write(require("node:fs").readFileSync(0,"utf8"))');
            assert.equal((await Child.run(node, echo, { ...base, input: "line one\n--two" })).stdout, "line one\n--two");
            assert.equal((await Child.run(node, echo, base)).stdout, "", "stdin without input is /dev/null");
        }],
        ["limit", async (Child, clock) => {
            const both = await Child.run(node, script('process.stdout.write("a".repeat(600));process.stderr.write("b".repeat(600));setInterval(()=>{},1000)'), { ...base, clock });
            assert.equal(both.kind, "stopped");
            assert.equal(both.reason, "output-limit");
            assert.equal(Buffer.byteLength(both.stdout) + Buffer.byteLength(both.stderr), 1024, "one ceiling over both streams");
            const invalid = await Child.run(node, script("process.stdout.write(Buffer.alloc(1024,255))"), base);
            assert.equal(invalid.reason, "output-limit", "replacement characters count as received text");
        }],
        ["deadline", async Child => {
            fs.rmSync(marker("held"), { force: true });
            // It exits by itself, so a copy without the deadline cannot hang.
            const held = `require("node:fs").writeFileSync(${JSON.stringify(marker("held"))},String(process.pid));setTimeout(()=>{},1000)`;
            const result = await Child.run(node, script(held), { ...base, clock: onReady(marker("held")) });
            assert.equal(result.kind, "stopped");
            assert.equal(result.reason, "timeout");
            assert.equal(alive(await ready(marker("held"))), false);
        }],
        ["group", async Child => {
            for (const name of ["member", "leader"]) fs.rmSync(marker(name), { force: true });
            const held = server("member", false) + `require("node:fs").writeFileSync(${JSON.stringify(marker("leader"))},String(process.pid));setInterval(()=>{},1000)`;
            const result = await Child.run(node, script(held), { ...base, clock: onReady(marker("leader")) });
            assert.equal(result.reason, "timeout");
            const member = await ready(marker("member"));
            cleanup.push(member);
            assert.equal(alive(member), false, "the end kills the whole group, not only its leader");
        }],
        ["ignored-output", async (Child, clock) => {
            fs.rmSync(marker("server"), { force: true });
            const result = await Child.run(node, script(server("server", true)), { ...base, output: "ignore", clock });
            assert.equal(result.kind, "exited", "the leader's exit closes the call while its server lives");
            assert.equal(result.code, 0);
            const pid = await ready(marker("server"));
            cleanup.push(pid);
            assert.equal(alive(pid), true, "a successful child's group is never ended");
            assert.notEqual(groupOf(pid), groupOf(process.pid), "the child leads its own group");
        }],
        ["cancel", async (Child, clock) => {
            fs.rmSync(marker("cancel"), { force: true });
            const abort = new AbortController();
            const held = `require("node:fs").writeFileSync(${JSON.stringify(marker("cancel"))},String(process.pid));setInterval(()=>{},1000)`;
            const running = Child.run(node, script(held), { ...base, signal: abort.signal, clock });
            const pid = await ready(marker("cancel"));
            abort.abort();
            const result = await running;
            assert.equal(result.kind, "stopped");
            assert.equal(result.reason, "cancelled");
            assert.equal(alive(pid), false);
            const before = new AbortController();
            before.abort();
            assert.deepEqual(await Child.run(node, script("process.exit(9)"), { ...base, signal: before.signal }),
                { kind: "stopped", reason: "cancelled", stdout: "", stderr: "" });
        }],
        ["spawn-error", async Child => {
            const result = await Child.run(path.join(root, "absent"), [], base);
            assert.deepEqual(result, { kind: "error", reason: "spawn", error: "ENOENT", stdout: "", stderr: "" });
        }]
    ];
    // name, the text kept, its replacement, the case it reddens, and whether
    // its broken copy needs the short bound to end a child.
    const controls = [
        ["deadline", 'const timer = clock.set(() => end("timeout"), deadline);', "const timer = clock.set(() => {}, deadline);", "deadline"],
        ["limit", 'if (bytes > limit) end("output-limit");', 'if (false) end("output-limit");', "limit", true],
        ["group-kill", 'try { process.kill(-child.pid, "SIGKILL"); }', 'try { process.kill(child.pid, "SIGKILL"); }', "group"],
        ["own-group", "detached: group,", "detached: false,", "ignored-output"],
        ["environment", "{ env, detached: group,", "{ env: { ...process.env, ...env }, detached: group,", "exited"],
        ["input", "child.stdin.end(input);", "child.stdin.end();", "input"],
        ["ignored-output", "output, output, ...Array", '"pipe", "pipe", ...Array', "ignored-output", true],
        ["cancel", 'if (signal) signal.addEventListener("abort", cancel, { once: true });', "void cancel;", "cancel", true]
    ];
    return (async () => {
        try {
            const Child = require(childFile);
            for (const [name, check] of cases) { await check(Child); console.log("case=" + name + " passed"); }
            for (const [name, needle, replacement, row, bound] of controls) {
                await mutant(childFile, name, needle, replacement, Child => cases.find(entry => entry[0] === row)[1](Child, bound ? bounded : undefined));
                console.log("control=" + name + " detected");
            }
            console.log("test-jarvis-child: ok cases=" + cases.length + " controls=" + controls.length);
        } finally {
            for (const pid of cleanup) if (alive(pid)) process.kill(pid, "SIGKILL");
        }
    })().catch(error => { console.error(error); process.exitCode = 1; });
});
