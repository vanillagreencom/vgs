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
const os = require("node:os");
const path = require("node:path");

const helper = path.join(__dirname, "lib/jarvis-env.sh");
const probe = path.join(__dirname, "fixtures/jarvis-env/probe.py");
const systemPath = "/usr/bin:/usr/sbin:/bin:/sbin";
class Unavailable extends Error {}

function run(command, args, env) {
    const result = cp.spawnSync(command, args, { env, cwd: env.HOME, encoding: "utf8", timeout: 60000 });
    if (result.error?.code === "ENOENT") throw new Unavailable("missing=" + command);
    if (result.error) throw result.error;
    if (result.signal) throw new Error("test-jarvis-env: child-signal=" + result.signal);
    if (result.status === 77) throw new Unavailable(result.stderr);
    return result;
}

function explicitEnv(root) {
    return { PATH: systemPath, HOME: path.join(root, "parent-home"), TMPDIR: root, LC_ALL: "C",
        JARVIS_PARENT_ONLY: "scrub-me", VGS_TEST_RUN: "1" };
}

async function main() {
    if (process.argv[2] !== "--inside") {
        const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "test-jarvis-env-")));
        fs.mkdirSync(path.join(root, "parent-home"));
        try {
            const result = cp.spawnSync("/usr/bin/unshare",
                ["-rn", "--pid", "--fork", "--mount-proc", "--kill-child", "--",
                    process.execPath, __filename, "--inside", root],
                { env: explicitEnv(root), cwd: root, encoding: "utf8", timeout: 180000 });
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
    function outbound(file) {
        const result = cli(file, standins, "python3", probe, "outbound", port);
        assert.equal(result.status, 1, result.stdout + result.stderr);
        assert.equal(result.stderr.trim(), "outbound=blocked errno=101");
    }
    function mutation(name, old, replacement, check, count = 1) {
        assert.equal(source.split(old).length - 1, count, name + ": mutation match");
        const changed = source.split(old).join(replacement);
        assert.notEqual(changed, source);
        const file = path.join(root, name + ".sh");
        fs.writeFileSync(file, changed);
        assert.equal(run("/bin/bash", ["-n", file], env).status, 0, name + ": syntax");
        assert.throws(() => check(file), assert.AssertionError, name + ": test must turn red");
        controls++;
        console.log("  ok    control=" + name);
    }
    function refusal(directory, key, file = helper) {
        const result = cli(file, directory, "true");
        assert.equal(result.status, 1, result.stderr);
        assert.equal(result.stderr.trim(), key);
    }

    try {
        const standinResult = cli(helper, standins, "jarvis-standin");
        assert.equal(standinResult.status, 0, standinResult.stderr);
        assert.equal(standinResult.stdout, "standin=ok\n");
        const sourced = run("/bin/bash", ["--noprofile", "--norc", "-c",
            'source "$1"; jarvis_env_run "$2" -- jarvis-standin', "probe", helper, standins], env);
        assert.equal(sourced.status, 0, sourced.stderr);
        assert.equal(sourced.stdout, "standin=ok\n");
        missingStandin(helper);
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
        for (const flag of ["-S", "-L", "-f"]) good(helper, "tmux-override", flag);
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
        for (const [key, suffix] of directories) {
            // All substituted paths remain inside the outer scratch world.
            mutation("scratch-" + key, key + '="$root/' + suffix + '"',
                key + '="' + path.join(root, "parent-home") + '"',
                file => good(file, "directory", key, suffix));
        }
        mutation("path-fallback", 'PATH="$root/standins:$root/tools"', 'PATH="$root/standins:$root/tools:$PATH"', missingStandin);
        mutation("allow-list", "timeout gdbus)", "timeout gdbus uname)", file => good(file, "path"));
        mutation("network", "-rn --pid", "-r --pid", outbound, 2);
        mutation("child-namespace", "--pid --fork --mount-proc --kill-child --", "--",
            file => good(file, "namespace", ...parentNamespaces), 2);
        mutation("child-lifetime", "--pid --fork --mount-proc --kill-child --", "--", lifetime, 2);
        mutation("session-bus", 'export DBUS_SESSION_BUS_ADDRESS="$address"',
            'export DBUS_SESSION_BUS_ADDRESS="$DBUS_SYSTEM_BUS_ADDRESS"', file => good(file, "buses"));
        mutation("system-bus", 'export DBUS_SYSTEM_BUS_ADDRESS="$address"',
            'export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"', file => good(file, "buses"));
        mutation("bus-activation", "'</busconfig>'", "'<standard_session_servicedirs/>' '</busconfig>'",
            file => good(file, "activation"));
        mutation("tmux-socket", '-S "$JARVIS_TEST_TMUX_SOCKET"', '-S "$JARVIS_TEST_ROOT/run/wrong.sock"',
            file => good(file, "tmux"));
        mutation("tmux-config", "-f /dev/null -S", '-f "$JARVIS_TEST_ROOT/home/.tmux.conf" -S',
            file => good(file, "tmux"));
        mutation("tmux-override", 'echo "jarvis-env: tmux=override-refused" >&2; exit 2 ;;',
            'echo "jarvis-env: tmux=override-refused" >&2; : ;;',
            file => good(file, "tmux-override", "-S"));
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
        const old = "cat -- \"$root/namespace.log\" >&2 || return 1\n    return 77";
        assert.equal(unavailableSource.split(old).length - 1, 1);
        const wrongStatus = path.join(root, "unavailable-status.sh");
        fs.writeFileSync(wrongStatus, unavailableSource.replace(old, old.replace("return 77", "return 1")));
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
