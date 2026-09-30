#!/usr/bin/env node
// Real bwrap inside the J09 world. No auth binary, live HOME, device or network.
"use strict";
const { assert, fs, path, tree, world, asyncControl } = require("./fixtures/jarvis/policy.js");
const net = require("node:net");
const { cases } = require("./fixtures/jarvis/forbidden.js");
const sourceFile = path.join(tree, "shell/plugins/vgs.jarvis/backend/Sandbox.js");
const control = asyncControl(sourceFile);
const Sandbox = require(sourceFile);
const Denied = require("../shell/plugins/vgs.jarvis/backend/Denied.js");
const Policy = require("../shell/plugins/vgs.jarvis/backend/Policy.js");
const Tools = require("../shell/plugins/vgs.jarvis/backend/Tools.js");

function seed() {
    const home = fs.realpathSync(process.env.HOME);
    const roots = { home, config: home + "/.config", data: home + "/.local/share",
        state: home + "/.local/state", runtime: process.env.XDG_RUNTIME_DIR,
        install: home + "/installation", accountRoots: [home + "/selected-account"] };
    const project = home + "/project";
    fs.mkdirSync(project);
    for (const key of ["config", "data", "state", "install"]) fs.mkdirSync(roots[key], { recursive: true });
    fs.mkdirSync(home + "/physical-account");
    fs.symlinkSync(home + "/physical-account", roots.accountRoots[0]);
    const denied = Denied.create(roots);
    // Seed only scratch roots. Runtime is outside HOME and never mounted.
    for (const root of denied.masks.filter(file => file.startsWith(home + "/"))) {
        fs.mkdirSync(root, { recursive: true });
        fs.writeFileSync(root + "/sentinel", "synthetic credential or policy\n");
    }
    const world = { home, project, roots };
    for (const row of cases(world).filter(row => row.file)) {
        fs.mkdirSync(path.dirname(row.file), { recursive: true });
        fs.writeFileSync(row.file, "synthetic protected content\n");
    }
    fs.writeFileSync(home + "/ordinary", "ordinary read-only content");
    fs.symlinkSync(home + "/.ssh", project + "/credential-alias");
    fs.symlinkSync(home + "/.ssh", home + "/credential-pointer");
    return world;
}

const node = "/usr/bin/node";
const js = code => [node, "-e", code];
const quoted = value => JSON.stringify(value);
const access = (file, operation) => js(`const f=require("node:fs");try{${operation === "read"
    ? `f.readFileSync(${quoted(file)})` : `f.writeFileSync(${quoted(file)},"planted")`};process.exit(0)}catch(e){process.stdout.write(e.code);process.exit(42)}`);
const request = (argv, cwd, network = false) => ({ argv, cwd, network });
function exited(result, code) {
    assert.equal(result.kind, "exited", JSON.stringify(result));
    assert.equal(result.code, code, JSON.stringify(result));
}
async function forbidden(sandbox, w, file, operation) {
    const result = await sandbox.run(request(access(file, operation), w.project), w.roots);
    exited(result, 42);
    assert.match(result.stdout, /^(EACCES|EROFS|ENOENT|EISDIR)$/);
}
async function main() {
    const available = await Sandbox.available();
    if (available.kind !== "available") {
        assert.equal(available.kind, "unavailable");
        console.log("jarvis-sandbox: status=not-verified " + JSON.stringify(available));
        process.exitCode = 77;
        return;
    }
    const w = seed();
    const denied = Denied.create(w.roots);
    const run = (argv, network = false, options = {}) => Sandbox.run(request(argv, w.project, network), w.roots, options);
    for (const row of cases(w)) {
        for (const profile of row.profiles || ["cautious", "standard", "trusted"]) {
            for (const call of row.calls) assert.equal(Policy.decide(call, {
                profile, locked: row.locked || false, taint: { kind: "clean" }, denied,
                input: row.input, grants: []
            }).reason, row.reason, row.name + " " + profile + " " + call.id);
        }
        if (row.file) for (const operation of ["read", "write"]) await forbidden(Sandbox, w, row.file, operation);
        console.log("forbidden=" + row.name + " refused");
    }
    // Every mask from the real owner, including physical account aliases.
    assert(denied.masks.length > 0, "Denied mask discovery must not be empty");
    assert(denied.masks.includes(w.home + "/.ssh"));
    assert(denied.masks.includes(w.roots.config + "/vgs"));
    for (const root of denied.masks) for (const operation of ["read", "write"])
        await forbidden(Sandbox, w, root + "/sentinel", operation);
    for (const operation of ["read", "write"]) await forbidden(Sandbox, w, w.project + "/credential-alias/sentinel", operation);
    for (const operation of ["read", "write"]) await forbidden(Sandbox, w, w.home + "/credential-pointer/sentinel", operation);
    // File-valued protection and absent parents use the same mask, not /dev/null.
    fs.rmSync(w.home + "/.netrc", { recursive: true });
    fs.writeFileSync(w.home + "/.netrc", "synthetic credential");
    for (const operation of ["read", "write"]) await forbidden(Sandbox, w, w.home + "/.netrc", operation);
    fs.rmSync(w.home + "/.gnupg", { recursive: true });
    for (const operation of ["read", "write"]) await forbidden(Sandbox, w, w.home + "/.gnupg/new/deep", operation);
    const maskDirectory = js(`try{require("node:fs").readdirSync(${quoted(w.home + "/.gnupg")});process.exit(0)}catch(e){process.exit(e.code==="EACCES"?42:43)}`);
    exited(await run(maskDirectory), 42);
    const maskWrite = js(`const f=require("node:fs");try{f.chmodSync(${quoted(w.home + "/.gnupg")},448);f.writeFileSync(${quoted(w.home + "/.gnupg/new")},"fixture");process.exit(0)}catch(e){process.exit(42)}`);
    exited(await run(maskWrite), 42);
    exited(await run(access(w.home + "/ordinary", "read")), 0);
    await forbidden(Sandbox, w, w.home + "/ordinary", "write");
    exited(await run(access(w.project + "/allowed", "write")), 0);
    assert.equal(fs.readFileSync(w.project + "/allowed", "utf8"), "planted");
    // Cwd ancestors and a replaced cwd link must be rejudged before the bind.
    for (const cwd of [w.home, w.roots.config, w.home + "/selected-account", w.project + "/credential-alias"])
        assert.deepEqual(await Sandbox.run(request(["pwd"], cwd), w.roots), { kind: "refused", reason: "protected-path" });
    assert.deepEqual(await Sandbox.run(request(["pwd"], w.project + "/absent"), w.roots),
        { kind: "refused", reason: "cwd-not-directory" });
    assert.deepEqual(await Sandbox.run(request(["pwd"], w.home + "/ordinary"), w.roots),
        { kind: "refused", reason: "cwd-not-directory" });
    const elevation = await run(js(`const fs=require("node:fs");const s=fs.readFileSync("/proc/self/status","utf8");process.exit(/^NoNewPrivs:\\s+1$/m.test(s)?42:0)`));
    exited(elevation, 42);
    // NNP belongs to bwrap itself, not editable Sandbox behavior. No production
    // mutation can remove it. This reads the kernel bit and starts no auth.
    const session = js(`process.exit(require("node:fs").readFileSync("/proc/self/stat","utf8").split(" ")[5]===${quoted(fs.readFileSync("/proc/self/stat", "utf8").split(" ")[5])}?0:42)`);
    exited(await run(session), 42);
    const device = js('process.exit(require("node:fs").existsSync("/dev/uinput") || require("node:fs").existsSync("/dev/dri") || require("node:fs").existsSync("/dev/snd") ? 0 : 42)');
    exited(await run(device), 42);
    const clean = js('process.exit(["DBUS_SESSION_BUS_ADDRESS","WAYLAND_DISPLAY","HYPRLAND_INSTANCE_SIGNATURE","PULSE_SERVER","VGSH_RUNNER_PID","JARVIS_TEST_ROOT"].some(k=>Object.hasOwn(process.env,k))?0:42)');
    exited(await run(clean), 42);
    const childEnv = await run(js('process.stdout.write(JSON.stringify(process.env))'));
    exited(childEnv, 0);
    assert.equal(JSON.parse(childEnv.stdout).XDG_RUNTIME_DIR, "/run/jarvis");
    const syscall = number => ["/usr/bin/python3", "-I", "-c",
        `import ctypes,errno,os\nc=ctypes.CDLL(None,use_errno=True)\nr=c.syscall(${number},0,0,0,0,0,0)\nos._exit(42 if r==-1 and ctypes.get_errno()==errno.EPERM else 0)\n`];
    for (const number of [425, 426, 427]) exited(await run(syscall(number)), 42);
    await control("io-uring", "[0x35, 0, 2, 425], [0x25, 1, 0, 427], [0x06, 0, 0, 0x00050001],",
        "[0x35, 0, 2, 425], [0x25, 1, 0, 427], [0x06, 0, 0, 0x7fff0000],", async s =>
            exited(await s.run(request(syscall(427), w.project), w.roots), 42));
    if (process.arch === "x64") {
        // Linux x86-64 raw compatibility getpid, not an auth/privilege probe.
        // int 0x80 uses AUDIT_ARCH_I386; the Python caller exits through its
        // native ABI. Bytes are mov eax,20; int 0x80; ret (Intel ISA).
        const compat = ["/usr/bin/python3", "-I", "-c",
            'import ctypes,mmap,os\nm=mmap.mmap(-1,8,prot=mmap.PROT_READ|mmap.PROT_WRITE|mmap.PROT_EXEC)\nm.write(bytes.fromhex("b814000000cd80c3"))\nf=ctypes.CFUNCTYPE(ctypes.c_int)(ctypes.addressof(ctypes.c_char.from_buffer(m)))\nos._exit(42 if f()==-1 else 0)\n'];
        exited(await run(compat), 42);
        await control("syscall-abi", "[0x15, 1, 0, abi[0]]", "[0x05, 0, 0, 1]", async s =>
            exited(await s.run(request(compat, w.project), w.roots), 42));
        const x32 = syscall(0x40000029);
        exited(await run(x32), 42);
        await control("x32", "[0x35, 0, 1, 0x40000000]", "[0x35, 0, 1, 0xffffffff]", async s =>
            exited(await s.run(request(x32, w.project), w.roots), 42));
    }
    // Only private loopback and private scratch Unix sockets. These cannot
    // reach a host bus or auth service even in a control.
    const accept = socket => socket.on("error", error => assert.equal(error.code, "ECONNRESET"));
    const tcp = net.createServer(accept);
    await new Promise(resolve => tcp.listen(0, "127.0.0.1", resolve));
    const socketPath = w.roots.runtime + "/desktop.fixture";
    const unix = net.createServer(accept);
    await new Promise(resolve => unix.listen(socketPath, resolve));
    const connect = target => js(`const n=require("node:net");const s=n.connect(${quoted(target)});s.on("connect",()=>{s.destroy();process.exit(0)});s.on("error",()=>process.exit(42));setTimeout(()=>process.exit(43),1000);`);
    const network = connect({ port: tcp.address().port, host: "127.0.0.1" });
    const endpoint = js('process.exit(require("node:fs").existsSync("/run/jarvis/desktop.fixture")?0:42)');
    const unixEndpoint = connect(socketPath);
    const abstractPath = "\0jarvis-fixture-" + process.pid;
    const abstract = net.createServer(accept);
    await new Promise(resolve => abstract.listen(abstractPath, resolve));
    const abstractEndpoint = connect(abstractPath);
    try {
        exited(await run(network), 42);
        exited(await run(network, true), 0);
        exited(await run(endpoint), 42);
        exited(await run(unixEndpoint, true), 42);
        exited(await run(abstractEndpoint, true), 42);
        assert.equal(Tools.refine({ id: "shell.argv", args: request(network, w.project, true) }).effect, "external");
        await control("network", "if (network) args.push", "if (true) args.push", async s => exited(await s.run(request(network, w.project), w.roots), 42));
        await control("runtime", '"--dir", "/run/jarvis"', `"--ro-bind", ${quoted(w.roots.runtime)}, "/run/jarvis"`,
            async s => exited(await s.run(request(endpoint, w.project), w.roots), 42));
        await control("unix-sockets", '"--seccomp", "4", ', "", async s =>
            exited(await s.run(request(abstractEndpoint, w.project, true), w.roots), 42));
    } finally { tcp.close(); unix.close(); abstract.close(); }
    await control("home-readonly", 'file === writable ? "--bind" : "--ro-bind"', 'file.startsWith(' + quoted(w.home) + ') ? "--bind" : "--ro-bind"',
        s => forbidden(s, w, w.home + "/ordinary", "write"));
    const maskCall = "mounts(args, [...denied.masks, roots.runtime, privateRuntime], home, target.path)";
    const omitMask = file => "mounts(args, [...denied.masks.filter(p => p !== " + quoted(file) + "), roots.runtime, privateRuntime], home, target.path)";
    await control("credential-mask", maskCall, omitMask(w.home + "/.ssh"),
        s => forbidden(s, w, w.home + "/.ssh/sentinel", "read"));
    await control("policy-mask", maskCall, omitMask(w.roots.config + "/vgs"),
        s => forbidden(s, w, w.roots.config + "/vgs/policy", "read"));
    await control("physical-alias", maskCall, omitMask(w.home + "/physical-account"),
        s => forbidden(s, w, w.home + "/physical-account/sentinel", "read"));
    await control("symlink-preservation", 'args.push("--symlink", fs.readlinkSync(file), file)',
        'args.push("--ro-bind", file, file)', s => forbidden(s, w, w.home + "/credential-pointer/sentinel", "read"));
    await control("mask-read", 'args.push("--perms", "000", "--tmpfs", file, "--remount-ro", file)',
        'args.push("--tmpfs", file, "--remount-ro", file)', async s => exited(await s.run(request(maskDirectory, w.project), w.roots), 42));
    await control("mask-write", 'args.push("--perms", "000", "--tmpfs", file, "--remount-ro", file)',
        'args.push("--perms", "000", "--tmpfs", file)', async s => exited(await s.run(request(maskWrite, w.project), w.roots), 42));
    await control("cwd-rejudge", 'denied.inspect(refined.call.args.cwd, "workspace")',
        '({kind:"path",path:refined.call.args.cwd,exists:true})', async s =>
            assert.deepEqual(await s.run(request(["pwd"], w.home), w.roots), { kind: "refused", reason: "protected-path" }));
    await control("new-session", '"--new-session", ', "", async s => exited(await s.run(request(session, w.project), w.roots), 42));
    // Device control exposes only a synthetic regular uinput file.
    const dev = w.home + "/device-fixture";
    fs.mkdirSync(dev);
    fs.writeFileSync(dev + "/uinput", "not a device");
    await control("private-dev", '"--dev", "/dev"', `"--bind", ${quoted(dev)}, "/dev"`, async s =>
        exited(await s.run(request(js('process.exit(require("node:fs").existsSync("/dev/uinput")?0:42)'), w.project), w.roots), 42));
    await control("environment", '"--clearenv", ', `"--setenv", "WAYLAND_DISPLAY", "fixture", `, async s =>
        exited(await s.run(request(clean, w.project), w.roots), 42));
    const output = js('process.stdout.write(Buffer.alloc(65537,65))');
    const bound = async s => {
        const result = await s.run(request(output, w.project), w.roots);
        assert.equal(result.kind, "stopped");
        assert.equal(result.reason, "output-limit");
        assert.equal(Buffer.byteLength(result.stdout), 65536);
    };
    await bound(Sandbox);
    const combined = await run(js('process.stdout.write(Buffer.alloc(32768,65));process.stderr.write(Buffer.alloc(32769,66))'));
    assert.equal(combined.kind, "stopped");
    assert.equal(combined.reason, "output-limit");
    assert.equal(Buffer.byteLength(combined.stdout) + Buffer.byteLength(combined.stderr), 65536);
    const invalid = await run(js('process.stdout.write(Buffer.alloc(65536,255))'));
    assert.equal(invalid.kind, "stopped");
    assert.equal(invalid.reason, "output-limit");
    assert(Buffer.byteLength(invalid.stdout) <= 65536);
    await control("output-bound", "if (bytes > LIMIT) end", "if (false) end", bound);
    // Readiness, not a real sleep, triggers the injected deadline/cancellation.
    const marker = w.project + "/ready";
    const held = js(`const f=require("node:fs");f.writeFileSync(${quoted(marker)},"ready");setInterval(()=>{},1000)`);
    const waitReady = async () => {
        for (let i = 0; i < 500 && !fs.existsSync(marker); i++) await new Promise(resolve => setTimeout(resolve, 10));
        assert(fs.existsSync(marker), "held fixture did not start");
    };
    async function timeout(s) {
        fs.rmSync(marker, { force: true });
        const abort = new AbortController();
        const clock = {
            set(fn, ms) { assert.equal(ms, 120000); waitReady().then(fn).catch(() => abort.abort()); return 1; },
            clear(timer) { assert.equal(timer, 1); }
        };
        const result = await s.run(request(held, w.project), w.roots, { clock, signal: abort.signal });
        assert.equal(result.kind, "stopped");
        assert.equal(result.reason, "timeout");
    }
    await timeout(Sandbox);
    // The mutant uses a fixture's exit, so a removed timeout never hangs.
    const finiteHeld = js(`const f=require("node:fs");f.writeFileSync(${quoted(marker)},"ready");setTimeout(()=>process.exit(0),100)`);
    await control("timeout", 'end("timeout")', 'void child.stdin', async s => {
        fs.rmSync(marker, { force: true });
        const result = await s.run(request(finiteHeld, w.project), w.roots, { clock: { set(fn, ms) { assert.equal(ms, 120000); setImmediate(fn); return 1; }, clear() {} } });
        assert.equal(result.kind, "stopped");
        assert.equal(result.reason, "timeout");
    });
    const abort = new AbortController();
    fs.rmSync(marker, { force: true });
    const cancelled = run(held, false, { signal: abort.signal });
    await waitReady();
    abort.abort();
    const cancelledResult = await cancelled;
    assert.equal(cancelledResult.kind, "stopped");
    assert.equal(cancelledResult.reason, "cancelled");
    const childFixture = w.project + "/child.py";
    fs.copyFileSync(path.join(tree, "scripts/fixtures/jarvis/sandbox-child.py"), childFixture);
    const lock = w.project + "/child.lock";
    const lockRead = ["/usr/bin/python3", "-I", "-c",
        'import fcntl,sys\nwith open(sys.argv[1],"w") as f:\n fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\n', lock];
    const cp = require("node:child_process");
    async function teardown(s) {
        fs.rmSync(marker, { force: true });
        const abort = new AbortController();
        const result = s.run(request(["/usr/bin/python3", "-I", childFixture, lock, marker], w.project), w.roots, { signal: abort.signal });
        await waitReady();
        abort.abort();
        assert.equal((await result).kind, "stopped");
        const probe = cp.spawnSync(lockRead[0], lockRead.slice(1), { env: { PATH: "/usr/bin:/bin" }, encoding: "utf8", timeout: 5000 });
        if (probe.error) throw probe.error;
        assert.equal(probe.status, 0, "descendant retained scratch lock: " + probe.stderr);
    }
    await teardown(Sandbox);
    await control("pid-teardown", '"--unshare-all", "--unshare-user"',
        '"--unshare-user", "--unshare-ipc", "--unshare-net", "--unshare-uts"', teardown);
    // J09 ends the surviving control child when this test world closes.
    const homeRuntime = w.home + "/alternate-runtime";
    fs.mkdirSync(homeRuntime);
    fs.writeFileSync(homeRuntime + "/sentinel", "synthetic runtime endpoint");
    const alternate = { ...w.roots, runtime: homeRuntime };
    const hiddenRuntime = async s => exited(await s.run(request(access(homeRuntime + "/sentinel", "read"), w.project), alternate), 42);
    await hiddenRuntime(Sandbox);
    await control("home-runtime", "mounts(args, [...denied.masks, roots.runtime, privateRuntime], home, target.path)",
        "mounts(args, denied.masks, home, target.path)", hiddenRuntime);
    const runtimeCwd = homeRuntime + "/workspace";
    fs.mkdirSync(runtimeCwd);
    assert.deepEqual(await Sandbox.run(request(["pwd"], runtimeCwd), alternate), { kind: "refused", reason: "runtime-workspace" });
    await control("runtime-cwd", "if (within(target.path, privateRuntime) || within(privateRuntime, target.path))", "if (false)", async s =>
        assert.deepEqual(await s.run(request(["pwd"], runtimeCwd), alternate), { kind: "refused", reason: "runtime-workspace" }));
    // Target output cannot impersonate bwrap's launch protocol.
    exited(await run(js('process.stdout.write(\'{"exit-code":0}\\n\');process.exit(7)')), 7);
    assert.equal((await run(["/absent/executable"])).kind, "error");
    const missing = js('process.exit(77)');
    exited(await run(missing), 77);
    // Unavailable bootstrap never executes the requested fixture.
    const empty = fs.mkdtempSync(path.join(process.env.JARVIS_TEST_ROOT, "missing-bwrap-"));
    for (const sibling of ["Denied.js", "Tools.js"]) fs.copyFileSync(path.join(path.dirname(sourceFile), sibling), path.join(empty, sibling));
    const original = fs.readFileSync(sourceFile, "utf8");
    const needle = 'for (const file of ["/usr/bin/bwrap", "/bin/bwrap"])';
    assert.equal(original.split(needle).length - 1, 1);
    fs.writeFileSync(path.join(empty, "Sandbox.js"), original.replace(needle, 'for (const file of [])'));
    const absent = require(path.join(empty, "Sandbox.js"));
    assert.deepEqual(await absent.available(), { kind: "unavailable", reason: "bwrap-missing" });
    assert.deepEqual(await absent.run(request(["/usr/bin/true"], w.project), w.roots), { kind: "unavailable", reason: "bwrap-missing" });
    fs.rmSync(empty, { recursive: true });
    await control("status-required",
        'if (records.length !== 2 || !Number.isSafeInteger(records[0]["child-pid"])\n'
        + '                || records[0]["child-pid"] <= 0 || !Number.isInteger(records[1]["exit-code"])\n'
        + '                || records[1]["exit-code"] < 0 || records[1]["exit-code"] > 255\n'
        + '                || records[1]["exit-code"] !== code || killed !== null)',
        'if (false)', async s =>
        assert.equal((await s.run(request(["/absent/executable"], w.project), w.roots)).reason, "launch-status"));
    console.log("jarvis-sandbox: real-bwrap forbidden operations and controls passed");
}

world(() => main().catch(error => { console.error(error); process.exitCode = 1; }));
