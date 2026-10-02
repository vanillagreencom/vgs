// Kernel command owner. The router still owns policy, approval and audit.
// REVISIT(D074): another host endpoint needs a typed control, not a wider bind.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const Child = require("./Child.js");
const Denied = require("./Denied.js");
const Tools = require("./Tools.js");

const LIMIT = 64 * 1024;
const DEADLINE = 120000;
const within = (file, root) => file === root || file.startsWith(root + "/");

function socketFilter() {
    // Linux seccomp_data and audit.h ABI. Reject compatibility syscall ABIs,
    // including x32, so they cannot bypass the native socket rule.
    const abi = { x64: [0xc000003e, 41, 53], arm64: [0xc00000b7, 198, 199] }[process.arch];
    if (!abi) throw new Error("jarvis: sandbox=unsupported-architecture");
    const instructions = [
        [0x20, 0, 0, 4], [0x15, 1, 0, abi[0]], [0x06, 0, 0, 0x00050001],
        [0x20, 0, 0, 0], [0x35, 0, 1, 0x40000000], [0x06, 0, 0, 0x00050001],
        // io_uring can create/connect sockets without the socket syscall.
        [0x35, 0, 2, 425], [0x25, 1, 0, 427], [0x06, 0, 0, 0x00050001],
        // Both constructors can supply a connectable Unix datagram endpoint.
        [0x15, 1, 0, abi[1]], [0x15, 0, 3, abi[2]], [0x20, 0, 0, 16],
        [0x15, 0, 1, 1], [0x06, 0, 0, 0x00050001], [0x06, 0, 0, 0x7fff0000]
    ];
    const data = Buffer.alloc(instructions.length * 8);
    instructions.forEach(([code, yes, no, value], index) => {
        data.writeUInt16LE(code, index * 8);
        data[index * 8 + 2] = yes;
        data[index * 8 + 3] = no;
        data.writeUInt32LE(value, index * 8 + 4);
    });
    return data;
}

function executable() {
    // Never search the caller's PATH or a workspace executable for bootstrap.
    for (const file of ["/usr/bin/bwrap", "/bin/bwrap"]) {
        try { fs.accessSync(file, fs.constants.X_OK); return file; }
        catch (error) { if (!["ENOENT", "EACCES"].includes(error.code)) throw error; }
    }
    return null;
}

function runtime(network) {
    const args = ["--die-with-parent", "--new-session", "--unshare-all", "--unshare-user", "--cap-drop", "ALL"];
    if (network) args.push("--share-net");
    args.push("--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--tmpfs", "/run",
        "--clearenv", "--setenv", "PATH", "/usr/bin:/bin", "--setenv", "LANG", "C.UTF-8",
        "--setenv", "TMPDIR", "/tmp", "--setenv", "XDG_RUNTIME_DIR", "/run/jarvis",
        "--dir", "/run/jarvis");
    return args;
}

/**
 * Rebuild only directories with protected descendants. Direct ro-bind of HOME
 * cannot add absent masks on its read-only mount. Empty read-only mounts deny
 * both current contents and creation. Preserve links, rather than bind their
 * targets at an unmasked alias. No credential contents enter this builder.
 */
function mount(args, file, masks, writable) {
    if (masks.some(root => within(file, root))) {
        args.push("--perms", "000", "--tmpfs", file, "--remount-ro", file);
        return;
    }
    let stat;
    try { stat = fs.lstatSync(file); }
    catch (error) { if (error.code !== "ENOENT") throw error; }
    if (stat && stat.isSymbolicLink()) {
        args.push("--symlink", fs.readlinkSync(file), file);
        return;
    }
    const descendants = masks.filter(root => within(root, file));
    if (stat && descendants.length === 0) {
        // A runtime socket or device is never a source mount.
        if (!stat.isDirectory() && !stat.isFile()) return;
        args.push(file === writable ? "--bind" : "--ro-bind", file, file);
        return;
    }
    if (stat && !stat.isDirectory()) throw new Error("jarvis: sandbox=mask-parent-not-directory");
    args.push("--perms", "0700", "--tmpfs", file);
    const names = new Set(stat ? fs.readdirSync(file) : []);
    for (const root of descendants) names.add(path.relative(file, root).split(path.sep)[0]);
    for (const name of [...names].sort()) mount(args, path.join(file, name), masks, writable);
    args.push("--remount-ro", file);
}

/**
 * Project selected public system data at its expected path. Resolve each
 * member against its source tree, not the projected directory: relative CA
 * links otherwise change meaning when a directory alias is flattened.
 * HOME uses mount(), which must preserve links instead.
 */
function publicRuntime(args, file, masks, input = file, ancestors = []) {
    try { fs.lstatSync(input); }
    catch (error) {
        if (error.code === "ENOENT" && ancestors.length === 0) return;
        throw error;
    }
    const source = fs.realpathSync.native(input);
    if (masks.some(root => within(file, root) || within(source, root) || within(root, source)))
        throw new Error("jarvis: sandbox=public-runtime-protected path=" + file);
    const stat = fs.statSync(source);
    if (stat.isFile() || (stat.isDirectory() && source === file)) {
        args.push("--ro-bind", source, file);
        return;
    }
    if (!stat.isDirectory()) throw new Error("jarvis: sandbox=public-runtime-kind path=" + file);
    if (ancestors.includes(source)) throw new Error("jarvis: sandbox=public-runtime-cycle path=" + file);
    args.push("--perms", "0755", "--tmpfs", file);
    for (const name of fs.readdirSync(source).sort())
        publicRuntime(args, path.join(file, name), masks, path.join(source, name), [...ancestors, source]);
    args.push("--remount-ro", file);
}

function mounts(args, masks, home, cwd) {
    mount(args, "/usr", masks, null);
    // Use each distribution's real runtime layout, including non-merged /usr.
    for (const file of ["/bin", "/sbin", "/lib", "/lib64"]) {
        try { fs.lstatSync(file); mount(args, file, masks, null); }
        catch (error) { if (error.code !== "ENOENT") throw error; }
    }
    // No host /etc wholesale: authentication and bus configuration stay out.
    // Public CA paths only. /etc/ssl/private and /etc/pki/tls/private stay out.
    for (const file of ["/etc/ssl/certs", "/etc/ssl/cert.pem", "/etc/ca-certificates",
        "/etc/pki/tls/certs", "/etc/pki/tls/cert.pem", "/etc/pki/ca-trust/extracted",
        "/etc/alternatives", "/etc/resolv.conf",
        "/etc/hosts", "/etc/nsswitch.conf", "/etc/localtime"]) {
        publicRuntime(args, file, masks);
    }
    if (home !== null) {
        mount(args, home, masks, null);
        args.push("--bind", cwd, cwd, "--chdir", cwd, "--setenv", "HOME", home);
    }
}

/**
 * Own acquisition, cancellation and namespace teardown. Child bounds the
 * output and lifetime. Only bwrap's separate status descriptor can establish
 * successful exec. A command cannot hide launch errors with stdout, stderr or
 * its exit code. The outside monitor closes that descriptor before the sandbox
 * child runs. bwrap's die-with-parent ends PID 1, then the kernel ends every
 * descendant, including children which called setsid themselves, so Child
 * ends bwrap alone rather than a process group.
 */
async function launch(binary, args, { signal, clock } = {}) {
    let filter;
    try { filter = socketFilter(); }
    catch (error) { return { kind: "error", reason: "socket-filter", error: error.message }; }
    let status = "";
    const result = await Child.run(binary, args, {
        env: { PATH: "/usr/bin:/bin", LANG: "C.UTF-8" }, limit: LIMIT, deadline: DEADLINE,
        group: false, extra: 2, signal, clock, attach: (child, end) => {
            child.stdio[3].on("data", chunk => {
                status += chunk.toString("utf8");
                if (status.length > 8192) end("status-limit");
            });
            // The bootstrap reads this pipe before exec and closes it. No filter
            // file or inherited endpoint exists in the sandbox.
            child.stdio[4].on("error", cause => { if (cause.code !== "EPIPE") end("filter-write"); });
            child.stdio[4].end(filter);
        }
    });
    if (result.kind !== "exited") return result;
    const { code, signal: killed, stdout, stderr } = result;
    let records;
    try { records = status.trim().split("\n").map(line => JSON.parse(line)); }
    catch { return { kind: "error", reason: "launch-status", stdout, stderr }; }
    if (records.length !== 2 || !Number.isSafeInteger(records[0]["child-pid"])
        || records[0]["child-pid"] <= 0 || !Number.isInteger(records[1]["exit-code"])
        || records[1]["exit-code"] < 0 || records[1]["exit-code"] > 255
        || records[1]["exit-code"] !== code || killed !== null)
        return { kind: "error", reason: "launch-status", stdout, stderr };
    return { kind: "exited", code, stdout, stderr };
}

function command(args, argv) {
    // Options must precede the separator. No request can supply bwrap flags.
    // Deny AF_UNIX even when external networking shares the parent's network
    // namespace. Abstract bus sockets have no pathname for a mount to hide.
    return [...args, "--json-status-fd", "3", "--seccomp", "4", "--", ...argv];
}

/**
 * J49 probes before offering shell tools. A missing binary, unsupported
 * bwrap option or unavailable namespace returns unavailable, never fallback.
 * This is a real kernel launch, not command presence or a version guess.
 */
async function available(options = {}) {
    const binary = executable();
    if (binary === null) return { kind: "unavailable", reason: "bwrap-missing" };
    const args = runtime(false);
    try { mounts(args, [], null, null); }
    catch (error) {
        return { kind: "unavailable", reason: "public-runtime", error: error.code || error.message };
    }
    const result = await launch(binary, command(args, ["/usr/bin/true"]), options);
    if (result.kind === "exited" && result.code === 0) return { kind: "available" };
    return { kind: "unavailable", reason: "bwrap-unavailable", detail: result };
}

/**
 * J49 supplies argv (a line becomes /bin/sh -c), cwd and network from its
 * immutable request, plus service-owned Denied roots and optional abort signal.
 * Rebuild Denied immediately before launch. This API grants no policy approval.
 * Results: exited(code), refused(reason), unavailable(reason), error(reason)
 * or stopped(reason). Every result must be matched by kind, never truthiness.
 * Limits are the Jarvis plan § Bounds, shared stdout/stderr bytes and elapsed
 * launch lifetime. The shell adapter reports clipping and never calls it success.
 */
async function run(request, roots, options = {}) {
    const refined = Tools.refine({ id: "shell.argv", args: request });
    if (refined.kind === "refuse") return { kind: "refused", reason: refined.reason };
    let args;
    try {
        const denied = Denied.create(roots);
        const target = denied.inspect(refined.call.args.cwd, "workspace");
        if (target.kind === "refuse") return { kind: "refused", reason: target.reason };
        if (!target.exists || !fs.statSync(target.path).isDirectory()) return { kind: "refused", reason: "cwd-not-directory" };
        const home = fs.realpathSync.native(roots.home);
        const privateRuntime = fs.realpathSync.native(roots.runtime);
        if (within(target.path, privateRuntime) || within(privateRuntime, target.path))
            return { kind: "refused", reason: "runtime-workspace" };
        args = runtime(refined.call.args.network);
        mounts(args, [...denied.masks, roots.runtime, privateRuntime], home, target.path);
    } catch (error) { return { kind: "error", reason: "filesystem", error: error.code || error.message }; }
    const binary = executable();
    if (binary === null) return { kind: "unavailable", reason: "bwrap-missing" };
    return launch(binary, command(args, refined.call.args.argv), options);
}

// The router consumes the same deadline; no adapter owns another command timer.
const BOUNDS = Object.freeze({ timeoutMs: DEADLINE, outputBytes: LIMIT });
module.exports = { available, run, BOUNDS };
