#!/usr/bin/env node
// Behavioral tests and one-rule mutations of scripts/lib/jarvis-env.sh.
// All cases, including mutations, run inside an outer user/network/PID
// namespace. Its synthetic 192.0.2.1 listener is the outbound control:
// removing the inner network namespace reaches it, never the real network.
// Missing host tools or namespaces exit 77, including during a control.
"use strict";
const assert = require("node:assert/strict");
const cp = require("node:child_process");
const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");

const helper = path.join(__dirname, "lib/jarvis-env.sh");
const probe = path.join(__dirname, "fixtures/jarvis-env/probe.py");
const systemPath = "/usr/bin:/usr/sbin:/bin:/sbin";
class Unavailable extends Error {}

function run(command, args, env, timeout = 60000) {
    const result = cp.spawnSync(command, args, { env, cwd: env.HOME, encoding: "utf8", timeout, killSignal: "SIGTERM" });
    if (result.error?.code === "ENOENT") throw new Unavailable("missing=" + command);
    if (result.error) throw result.error;
    if (result.signal) throw new Error("test-jarvis-env: child-signal=" + result.signal);
    if (result.status === 77) throw new Unavailable(result.stderr);
    return result;
}

function explicitEnv(root) {
    return { PATH: systemPath, HOME: path.join(root, "parent-home"), TMPDIR: root, LC_ALL: "C",
        JARVIS_TEST_SCRATCH_ROOT: root, JARVIS_PARENT_ONLY: "scrub-me", VGS_TEST_RUN: "1" };
}

// This is the suite's namespace supervisor, not a CLI world owner with TERM
// traps. SIGKILL is required because unshare --fork ignores TERM while waiting.
function runNamespace(args, env, timeout = 180000) {
    return cp.spawnSync("/usr/bin/unshare",
        ["-rn", "--pid", "--fork", "--mount-proc", "--kill-child", "--", ...args],
        { env, cwd: env.HOME, encoding: "utf8", timeout, killSignal: "SIGKILL" });
}

function namespaceTimeout(root) {
    const env = explicitEnv(root);
    const lock = path.join(root, "timeout.lock");
    const started = process.hrtime.bigint();
    // A real timeout: the fixture has a live descendant and output pipe, and
    // must be cancelled before it emits its natural-expiration marker.
    const result = runNamespace(["/usr/bin/python3", probe, "timeout-world", lock], env, 1000);
    assert.equal(result.error?.code, "ETIMEDOUT");
    assert.match(result.stdout, /"root": null/, "the descendant must start before timeout");
    assert.equal(result.signal, "SIGKILL");
    assert.doesNotMatch(result.stdout, /fixture=expired/, "timeout must stop the running fixture");
    assert.equal(run("/usr/bin/python3", [probe, "acquire", lock], env).status, 0, "timeout must end the descendant");
    console.log("  ok    namespace-timeout elapsed-ms=" + Number(process.hrtime.bigint() - started) / 1e6);
}

async function main() {
    if (process.argv[2] === "--namespace-timeout") {
        namespaceTimeout(process.argv[3]);
        return;
    }
    if (process.argv[2] !== "--inside") {
        const parent = path.resolve(__dirname, "../tmp");
        fs.mkdirSync(parent, { recursive: true });
        const root = fs.realpathSync(fs.mkdtempSync(path.join(parent, "je-")));
        fs.mkdirSync(path.join(root, "parent-home"));
        try {
            const result = runNamespace([process.execPath, __filename, "--inside", root], explicitEnv(root));
            if (result.error?.code === "ENOENT") throw new Unavailable("missing=unshare");
            if (result.error) throw result.error;
            process.stdout.write(result.stdout);
            process.stderr.write(result.stderr);
            if (result.signal) throw new Error("test-jarvis-env: child-signal=" + result.signal);
            // The inner suite writes this only after namespace creation.
            if (!fs.existsSync(path.join(root, "started"))) throw new Unavailable("reason=namespaces-unavailable");
            process.exitCode = result.status;
        } finally {
            fs.rmSync(root, { recursive: true, force: true });
        }
        return;
    }

    const root = process.argv[3];
    const env = explicitEnv(root);
    fs.writeFileSync(path.join(root, "started"), "");
    for (const args of [["link", "set", "lo", "up"], ["addr", "add", "192.0.2.1/32", "dev", "lo"]]) {
        const result = run("/usr/bin/ip", args, env);
        assert.equal(result.status, 0, result.stderr);
    }
    const server = net.createServer(stream => stream.end());
    await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "192.0.2.1", resolve); });
    const port = String(server.address().port);
    const standins = path.join(root, "standins");
    const missing = path.join(root, "missing");
    fs.mkdirSync(standins);
    fs.mkdirSync(missing);
    fs.writeFileSync(path.join(standins, "jarvis-standin"), "#!/bin/sh\nprintf 'standin=ok\\n'\n", { mode: 0o700 });
    // A harmless host-command fixture, outside the world's PATH. Appending
    // the caller's PATH must make the missing-stand-in case turn red.
    const hostTools = path.join(root, "parent-tools");
    fs.mkdirSync(hostTools);
    fs.writeFileSync(path.join(hostTools, "jarvis-standin"), "#!/bin/sh\nprintf 'standin=host-fallback\\n'\n", { mode: 0o700 });
    fs.writeFileSync(path.join(hostTools, "sudo"), "#!/bin/sh\nprintf 'auth=parent-standin\\n'\n", { mode: 0o700 });
    env.PATH = hostTools + ":" + systemPath;
    const parentNamespaces = ["user", "net", "pid"].map(kind => fs.readlinkSync("/proc/self/ns/" + kind));
    const source = fs.readFileSync(helper, "utf8");
    let controls = 0;
    let cases = 0;

    function cli(file, directory, ...args) {
        return run("/bin/bash", ["--noprofile", "--norc", file, directory, "--", ...args], env);
    }
    function good(file, mode, ...args) {
        const result = cli(file, standins, "python3", probe, mode, ...args);
        assert.equal(result.status, 0, mode + ": " + result.stderr);
        cases++;
        return result;
    }
    function missingStandin(file) {
        const result = cli(file, missing, "bash", "-c", "jarvis-standin");
        assert.equal(result.status, 127, result.stdout + result.stderr);
    }
    function missingAuth(file) {
        // Lookup only. A broken PATH must never execute a host auth program.
        const result = cli(file, missing, "bash", "-c", "command -v sudo");
        assert.equal(result.status, 1, result.stdout + result.stderr);
        assert.equal(result.stdout, "");
    }
    function outbound(file) {
        const result = cli(file, standins, "python3", probe, "outbound", port);
        assert.equal(result.status, 1, result.stdout + result.stderr);
        assert.equal(result.stderr.trim(), "outbound=blocked errno=101");
    }
    function mutationFile(name, old, replacement, count = 1) {
        assert.equal(source.split(old).length - 1, count, name + ": mutation match");
        const changed = source.split(old).join(replacement);
        assert.notEqual(changed, source);
        const file = path.join(root, name + ".sh");
        fs.writeFileSync(file, changed);
        assert.equal(run("/bin/bash", ["-n", file], env).status, 0, name + ": syntax");
        return file;
    }
    function mutation(name, old, replacement, check, count = 1) {
        const file = mutationFile(name, old, replacement, count);
        assert.throws(() => check(file), assert.AssertionError, name + ": test must turn red");
        controls++;
        console.log("  ok    control=" + name);
    }
    function refusal(directory, key, file = helper) {
        const result = cli(file, directory, "true");
        assert.equal(result.status, 1, result.stderr);
        assert.equal(result.stderr.trim(), key);
    }
    function scratchLocation(file, parent, overrides = {}) {
        const result = run("/bin/bash", [file, standins, "--", "python3", probe, "scratch-parent", parent],
            { ...env, ...overrides });
        assert.equal(result.status, 0, result.stderr);
        const allocated = result.stdout.trim();
        assert.equal(path.dirname(allocated), fs.realpathSync(parent));
        assert.equal(fs.existsSync(allocated), false, "owner removes the allocated world");
    }
    function scratchRefusal(file, parent, key) {
        const result = run("/bin/bash", [file, standins, "--", "true"],
            { ...env, JARVIS_TEST_SCRATCH_ROOT: parent });
        assert.equal(result.status, 1, result.stderr);
        assert.equal(result.stdout, "");
        assert.equal(result.stderr.trim(), key);
    }

    async function cancellation(file, signal) {
        const lock = path.join(root, "cancel.lock");
        const started = process.hrtime.bigint();
        // The owned group is a safety net for intentionally broken copies.
        // The assertion samples cleanup before this fallback removes anything.
        const launcher = cp.spawn("/bin/bash",
            ["--noprofile", "--norc", file, standins, "--", "python3", probe, "cancel", lock],
            { env, cwd: env.HOME, detached: true, stdio: ["ignore", "pipe", "pipe"] });
        let stdout = "", stderr = "", world, atExit, forced = false;
        const closed = new Promise((resolve, reject) => {
            launcher.once("error", reject);
            launcher.once("close", (code, received) => resolve({ code, signal: received }));
        });
        const ready = new Promise((resolve, reject) => {
            launcher.stdout.on("data", data => {
                stdout += data;
                if (!world && stdout.includes("\n")) {
                    try {
                        world = JSON.parse(stdout.split("\n")[0]).root;
                        resolve();
                    } catch (error) { reject(error); }
                }
            });
            launcher.once("error", reject);
            launcher.once("close", code => {
                if (!world) reject(code === 77 ? new Unavailable(stderr) : new Error("cancellation fixture did not start: " + stderr));
            });
        });
        launcher.stderr.on("data", data => { stderr += data; });
        launcher.once("exit", () => {
            atExit = { removed: world && !fs.existsSync(world),
                descendantEnded: run("/usr/bin/python3", [probe, "acquire", lock], env).status === 0 };
        });
        const watchdog = setTimeout(() => {
            forced = true;
            try { process.kill(-launcher.pid, "SIGKILL"); } catch (error) {
                if (error.code !== "ESRCH") throw error;
            }
        }, 5000); // Bounds a deliberately broken cleanup control, never a pass.
        try {
            await ready;
            assert.equal(launcher.kill(signal), true, "signal the exact CLI PID");
            const result = await closed; // close also proves both output pipes reached EOF.
            assert.equal(forced, false, "cancellation must not need the test watchdog");
            assert.equal(atExit.removed, true, "scratch must be removed before the CLI exits");
            assert.equal(atExit.descendantEnded, true, "descendant must end before the CLI exits");
            assert.doesNotMatch(stdout, /fixture=expired/, "cancelled fixture must not run to natural expiry");
            assert.equal(result.code, { SIGTERM: 143, SIGINT: 130, SIGHUP: 129 }[signal], stderr);
            assert.equal(result.signal, null, "the CLI must handle cancellation");
            console.log("  ok    cancellation=" + signal + " elapsed-ms=" + Number(process.hrtime.bigint() - started) / 1e6);
        } finally {
            clearTimeout(watchdog);
            // Never leave the disabled-cleanup control's process group alive.
            try { process.kill(-launcher.pid, "SIGKILL"); } catch (error) {
                if (error.code !== "ESRCH") throw error;
            }
            await closed;
            if (world) fs.rmSync(world, { recursive: true, force: true });
        }
    }

    function cliTimeout(file) {
        const lock = path.join(root, "cli-timeout.lock");
        const record = path.join(root, "cli-timeout.json");
        fs.rmSync(record, { force: true });
        const started = process.hrtime.bigint();
        // Use the shipped synchronous caller's actual timeout path. Its TERM
        // must reach the CLI owner and close the descendant's inherited pipe.
        assert.throws(() => run("/bin/bash",
            [file, standins, "--", "python3", probe, "cli-timeout", lock, record], env, 1000),
        error => error.code === "ETIMEDOUT");
        const result = JSON.parse(fs.readFileSync(record, "utf8"));
        assert.equal(result.expired, undefined, "CLI timeout must cancel, not wait for natural expiry");
        assert.equal(fs.existsSync(result.root), false, "CLI timeout must remove scratch");
        assert.equal(run("/usr/bin/python3", [probe, "acquire", lock], env).status, 0, "CLI timeout must end descendants");
        console.log("  ok    cli-timeout elapsed-ms=" + Number(process.hrtime.bigint() - started) / 1e6);
    }

    try {
        const standinResult = cli(helper, standins, "jarvis-standin");
        scratchLocation(helper, root);
        const defaultEnv = { ...env };
        delete defaultEnv.JARVIS_TEST_SCRATCH_ROOT;
        const defaultResult = run("/bin/bash",
            [helper, standins, "--", "python3", probe, "scratch-parent", path.resolve(__dirname, "../tmp")], defaultEnv);
        assert.equal(defaultResult.status, 0, defaultResult.stderr);
        assert.equal(fs.existsSync(defaultResult.stdout.trim()), false);
        const alias = path.join(root, "alias");
        fs.symlinkSync(root, alias);
        scratchLocation(helper, root, { JARVIS_TEST_SCRATCH_ROOT: alias });
        const special = path.join(root, "space & parent");
        scratchLocation(helper, special, { JARVIS_TEST_SCRATCH_ROOT: special });
        scratchRefusal(helper, "", "jarvis-env: scratch-parent=empty");
        const parentFile = path.join(root, "parent-file");
        fs.writeFileSync(parentFile, "");
        scratchRefusal(helper, parentFile, "jarvis-env: scratch-parent=create-failed path=" + parentFile);
        mutation("scratch-parent", 'scratch="${JARVIS_TEST_SCRATCH_ROOT-${self%/*}/../../tmp}"',
            'scratch="' + path.join(root, "other") + '"', file => scratchLocation(file, root));
        mutation("scratch-empty", '[[ -n $scratch ]]', '[[ -n $scratch ]] || true',
            file => scratchRefusal(file, "", "jarvis-env: scratch-parent=empty"));
        const allocatedTarget = path.join(root, "allocated-real");
        const allocatedAlias = path.join(root, "allocated-alias");
        fs.mkdirSync(allocatedTarget);
        fs.symlinkSync(allocatedTarget, allocatedAlias);
        const allocation = 'print(tempfile.mkdtemp(prefix="jv-", dir=sys.argv[1]))';
        const linked = mutationFile("allocated-link", allocation, 'print(sys.argv[1] + "/allocated-alias")');
        const linkedKey = "jarvis-env: scratch=not-a-directory value=[" + allocatedAlias + "]";
        scratchRefusal(linked, root, linkedKey);
        const linkGuard = "[[ -d $root && ! -L $root ]]";
        const linkSource = fs.readFileSync(linked, "utf8");
        assert.equal(linkSource.split(linkGuard).length - 1, 1);
        const acceptedLink = path.join(root, "accepted-link.sh");
        fs.writeFileSync(acceptedLink, linkSource.replace(linkGuard, linkGuard + " || [[ -d $root ]]"));
        assert.throws(() => scratchRefusal(acceptedLink, root, linkedKey), assert.AssertionError);
        controls++;
        assert.equal(standinResult.status, 0, standinResult.stderr);
        assert.equal(standinResult.stdout, "standin=ok\n");
        const sourced = run("/bin/bash", ["--noprofile", "--norc", "-c",
            'trap "printf caller-exit" EXIT; umask 022; before="$PWD"; source "$1"; jarvis_env_run "$2" -- jarvis-standin; [[ "$PWD" == "$before" && $(umask) == 0022 && "$JARVIS_PARENT_ONLY" == scrub-me ]]', "probe", helper, standins], env);
        assert.equal(sourced.status, 0, sourced.stderr);
        assert.equal(sourced.stdout, "standin=ok\ncaller-exit");
        missingStandin(helper);
        missingAuth(helper);
        const authStandins = path.join(root, "auth-standins");
        fs.mkdirSync(authStandins);
        fs.writeFileSync(path.join(authStandins, "sudo"), "#!/bin/sh\nprintf 'auth=world-standin\\n'\n", { mode: 0o700 });
        const authResult = cli(helper, authStandins, "sudo", "--fixture-only");
        assert.equal(authResult.status, 0, authResult.stderr);
        assert.equal(authResult.stdout, "auth=world-standin\n");
        outbound(helper);
        // Prove the synthetic outbound destination is reachable before
        // relying on it for the missing-namespace mutation.
        assert.equal(run("/usr/bin/python3", [probe, "outbound", port], env).status, 0);
        good(helper, "namespace", ...parentNamespaces);
        good(helper, "loopback");
        good(helper, "environment");
        good(helper, "path");
        good(helper, "buses");
        good(helper, "activation");
        good(helper, "tmux");
        const tmuxShapes = ["socket", "label", "config", "cluster-socket", "attached-socket",
            "cluster-config", "attached-config", "cluster-label", "post-feature-socket",
            "post-attached-feature-config", "post-cluster-feature-label", "post-command-socket"];
        for (const shape of tmuxShapes) {
            good(helper, "tmux-getopt", shape);
            good(helper, "tmux-override", shape);
        }
        for (const shape of ["unknown", "missing-value"]) good(helper, "tmux-override", shape);
        for (const options of [[], ["-u2"], ["-T", "256"], ["-T256"], ["-uT256"], ["-T", "-S"], ["--"]]) {
            good(helper, "tmux-safe", ...options);
        }
        good(helper, "tmux-command");
        for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) await cancellation(helper, signal);
        cliTimeout(helper);
        namespaceTimeout(root);
        good(helper, "audio");
        const directories = [
            ["HOME", "home"], ["XDG_CONFIG_HOME", "config"], ["XDG_DATA_HOME", "data"],
            ["XDG_STATE_HOME", "state"], ["XDG_CACHE_HOME", "cache"],
            ["TMPDIR", "tmp"], ["TMUX_TMPDIR", "run"], ["XDG_RUNTIME_DIR", "run"],
        ];
        for (const [key, suffix] of directories) good(helper, "directory", key, suffix);
        const lock = path.join(root, "orphan.lock");
        function lifetime(file) {
            const result = good(file, "orphan", lock);
            assert.equal(fs.existsSync(result.stdout.trim()), false, "scratch must be removed");
            assert.equal(run("/usr/bin/python3", [probe, "acquire", lock], env).status, 0, "descendant must end");
        }
        lifetime(helper);
        for (const status of [0, 1, 23, 77]) {
            const result = cp.spawnSync("/bin/bash", [helper, standins, "--", "bash", "-c", "exit " + status],
                { env, cwd: env.HOME, encoding: "utf8", timeout: 60000 });
            assert.equal(result.status, status, result.stderr);
        }
        mutation("scrub", "/usr/bin/env -i\n", "/usr/bin/env\n", file => good(file, "environment"));
        mutation("scratch-setting-leak", 'JARVIS_TEST_ROOT="$root")',
            'JARVIS_TEST_ROOT="$root" JARVIS_TEST_SCRATCH_ROOT="$scratch")', file => good(file, "environment"));
        for (const [key, suffix] of directories) {
            // All substituted paths remain inside the outer scratch world.
            mutation("scratch-" + key, key + '="$root/' + suffix + '"',
                key + '="' + path.join(root, "parent-home") + '"',
                file => good(file, "directory", key, suffix));
        }
        mutation("path-fallback", 'PATH="$root/standins:$root/tools"', 'PATH="$root/standins:$root/tools:$PATH"', missingStandin);
        mutation("auth-path-fallback", 'PATH="$root/standins:$root/tools"', 'PATH="$root/standins:$root/tools:$PATH"', missingAuth);
        mutation("allow-list", "timeout gdbus)", "timeout gdbus uname)", file => good(file, "path"));
        mutation("network", "-rn --pid", "-r --pid", outbound, 2);
        mutation("child-namespace", "--pid --fork --mount-proc --kill-child --", "--",
            file => good(file, "namespace", ...parentNamespaces), 2);
        mutation("child-lifetime", "--pid --fork --mount-proc --kill-child --", "--", lifetime, 2);
        mutation("session-bus", 'export DBUS_SESSION_BUS_ADDRESS="$address"',
            'export DBUS_SESSION_BUS_ADDRESS="$DBUS_SYSTEM_BUS_ADDRESS"', file => good(file, "buses"));
        mutation("system-bus", 'export DBUS_SYSTEM_BUS_ADDRESS="$address"',
            'export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"', file => good(file, "buses"));
        mutation("bus-activation", "</policy></busconfig>", "</policy><standard_session_servicedirs/></busconfig>",
            file => good(file, "activation"));
        mutation("tmux-socket", '-S "$JARVIS_TEST_TMUX_SOCKET"', '-S "$JARVIS_TEST_ROOT/run/wrong.sock"',
            file => good(file, "tmux"));
        mutation("tmux-config", "-f /dev/null -S", '-f "$JARVIS_TEST_ROOT/home/.tmux.conf" -S',
            file => good(file, "tmux"));
        for (const shape of tmuxShapes) {
            mutation("tmux-override-" + shape, 'echo "jarvis-env: tmux=override-refused" >&2; exit 2 ;;',
                'echo "jarvis-env: tmux=override-refused" >&2; : ;;',
                file => good(file, "tmux-override", shape));
        }
        for (const shape of ["cluster-socket", "cluster-config", "post-feature-socket", "post-attached-feature-config"]) {
            mutation("tmux-parsing-" + shape, 'case "$option" in', 'case "${1:1:1}" in',
                file => good(file, "tmux-override", shape));
        }
        const termOwner = mutationFile("ignored-owner-signal", 'kill -KILL "$owner"', 'kill -TERM "$owner"');
        await assert.rejects(cancellation(termOwner, "SIGTERM"), assert.AssertionError);
        assert.throws(() => cliTimeout(termOwner), assert.AssertionError);
        controls++;
        const wrongCli = mutationFile("cli-subshell", '    _jarvis_env_run "$@"', '    jarvis_env_run "$@"');
        await assert.rejects(cancellation(wrongCli, "SIGTERM"), assert.AssertionError);
        controls++;
        // Exercise the real suite supervisor's timeout through a copied suite.
        const nodeCopy = path.join(root, "node-control");
        fs.mkdirSync(path.join(nodeCopy, "fixtures/jarvis-env"), { recursive: true });
        fs.copyFileSync(probe, path.join(nodeCopy, "fixtures/jarvis-env/probe.py"));
        const suiteSource = fs.readFileSync(__filename, "utf8");
        const timeoutSignal = 'timeout, ' + 'killSignal: "SIGKILL"';
        assert.equal(suiteSource.split(timeoutSignal).length - 1, 1);
        const ignoredTimeout = suiteSource.replace(timeoutSignal, 'timeout, killSignal: "SIGTERM"');
        assert.notEqual(ignoredTimeout, suiteSource);
        const nodeMutant = path.join(nodeCopy, "test-jarvis-env.js");
        fs.writeFileSync(nodeMutant, ignoredTimeout);
        const timeoutResult = run(process.execPath, [nodeMutant, "--namespace-timeout", root], env);
        assert.equal(timeoutResult.status, 1);
        assert.match(timeoutResult.stderr, /AssertionError/);
        assert.match(timeoutResult.stderr, /SIGKILL/);
        controls++;
        for (const [key, value] of [
            ["PIPEWIRE_RUNTIME_DIR", '"$root/run"'], ["PIPEWIRE_REMOTE", "jarvis-test-no-pipewire"],
            ["PULSE_RUNTIME_PATH", '"$root/run"'], ["PULSE_SERVER", '"unix:$root/run/no-pulse"'],
        ]) {
            mutation("audio-" + key, key + "=" + value, key + "=wrong",
                file => good(file, "audio"));
        }
        const invalid = [
            ["link", () => fs.symlinkSync("/usr/bin/true", path.join(root, "link/tool"))],
            ["directory", () => fs.mkdirSync(path.join(root, "directory/tool"))],
            ["non-executable", () => fs.writeFileSync(path.join(root, "non-executable/tool"), "", { mode: 0o600 })],
        ];
        for (const [name, plant] of invalid) {
            const directory = path.join(root, name);
            fs.mkdirSync(directory);
            plant();
            const key = "jarvis-env: standin=not-executable-file name=tool";
            refusal(directory, key);
            const old = "[[ ! -f $entry || ! -x $entry || -L $entry ]]";
            // Preserve the matching condition, remove just its refusal.
            mutation("standin-" + name, old, old + " && false",
                file => refusal(directory, key, file));
        }
        const collision = path.join(root, "collision");
        fs.mkdirSync(collision);
        fs.writeFileSync(path.join(collision, "cat"), "#!/bin/sh\nexit 0\n", { mode: 0o700 });
        refusal(collision, "jarvis-env: standin=host-tool-collision name=cat");
        mutation("collision", "[[ -e $root/tools/$name || -e $root/bootstrap/$name ]]",
            "[[ -e $root/tools/$name || -e $root/bootstrap/$name ]] && false",
            file => refusal(collision, "jarvis-env: standin=host-tool-collision name=cat", file));
        // Namespace-unavailable handling: the probe cannot launch anything.
        const unavailable = path.join(root, "unavailable.sh");
        const needle = '"${clean_env[@]}" "$root/bootstrap/unshare" -rn --pid --fork --mount-proc --kill-child -- \\\n    "$root/tools/true"';
        assert.equal(source.split(needle).length - 1, 1);
        const unavailableSource = source.replace(needle, '"${clean_env[@]}" "$root/tools/false"');
        fs.writeFileSync(unavailable, unavailableSource);
        function unavailableCase(file) {
            const marker = path.join(root, "must-not-start");
            const result = cp.spawnSync("/bin/bash", [file, standins, "--", "bash", "-c", 'printf started >"$1"', "probe", marker],
                { env, cwd: env.HOME, encoding: "utf8", timeout: 60000 });
            assert.equal(result.status, 77, result.stderr);
            assert.equal(result.stderr.trim(), "jarvis-env: status=not-measured reason=namespaces-unavailable");
            assert.equal(fs.existsSync(marker), false);
        }
        unavailableCase(unavailable);
        const old = "cat -- \"$root/namespace.log\" >&2 || exit 1\n    exit 77";
        assert.equal(unavailableSource.split(old).length - 1, 1);
        const wrongStatus = path.join(root, "unavailable-status.sh");
        fs.writeFileSync(wrongStatus, unavailableSource.replace(old, old.replace("exit 77", "exit 1")));
        assert.throws(() => unavailableCase(wrongStatus), assert.AssertionError);
        controls++;
        console.log("test-jarvis-env: ok cases=" + cases + " controls=" + controls);
    } finally {
        server.close();
    }
}

main().catch(error => {
    if (error instanceof Unavailable) {
        console.error("test-jarvis-env: status=not-measured " + error.message.trim());
        process.exitCode = 77;
    } else {
        console.error(error);
        process.exitCode = 1;
    }
});
