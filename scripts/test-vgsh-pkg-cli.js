#!/usr/bin/env node
// The bin/vgsh-pkg CLI with the `vgsh pkg` verb (D034). Every expected
// value below was written by hand from the command output, never read from
// the implementation under test.
//
// - The CLI runs with a PATH of stub commands; `detect`, `owner` and a
//   `check` without --source read a fixture os-release bound over
//   /etc/os-release under `unshare -rm`. Without user namespaces those rows
//   cannot run and the suite exits 77.
// - The `check` rows run with stub managers and prove query parsing, locking,
//   timeout cleanup, signal cleanup and checkupdates freshness.
//
// The controls at the end edit a copy of bin/vgsh-pkg or bin/vgsh, one rule
// at a time, and require this suite to fail on each copy.
"use strict";
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { repo, TABLE, FIXTURES } = require("./vgsh-pkg-shared.js");
const PKG = path.join(repo, "bin", "vgsh-pkg");
const VGSH = path.join(repo, "bin", "vgsh");

// A tree at DIR holding bin/vgsh-pkg, bin/vgsh and the table as the texts
// given, and the repository's own bin/lib, which holds the loader, and the
// shipped shell.json with the configuration judge a plan that elevates
// reads: `{ pkg, vgsh }`.
function makeTree(dir, texts) {
    for (const sub of ["bin", "config", path.join("shell", "Core"), path.join("shell", "Commons"), path.join("shell", "Ui", "icons")]) fs.mkdirSync(path.join(dir, sub), { recursive: true });
    fs.symlinkSync(path.join(repo, "bin", "lib"), path.join(dir, "bin", "lib"));
    for (const file of ["config/shell.json", "shell/Core/PluginLogic.js", "shell/Core/HyprlandLayer.js", "shell/Commons/SettingValues.js", "shell/Ui/icons/Lucide.js"])
        fs.symlinkSync(path.join(repo, file), path.join(dir, file));
    fs.writeFileSync(path.join(dir, "shell", "Core", "PackageManagers.js"), texts.table);
    fs.writeFileSync(path.join(dir, "bin", "vgsh-pkg"), texts.pkg, { mode: 0o755 });
    fs.writeFileSync(path.join(dir, "bin", "vgsh"), texts.vgsh, { mode: 0o755 });
    return { pkg: path.join(dir, "bin", "vgsh-pkg"), vgsh: path.join(dir, "bin", "vgsh") };
}

// The table with the aur query's timeout cut to one second, for the row
// that proves a query is killed at its timeout without waiting two minutes.
const AUR_QUERY = "\"-Qua\"], exits: { \"0\": \"updates\", \"1\": \"none\" }, parser: \"arrow\", timeout: ";
function quickTable(text) {
    const count = text.split(AUR_QUERY + "120,").length - 1;
    if (count !== 1) throw new Error("quick table: the aur query occurs " + count + " times, not once");
    return text.replace(AUR_QUERY + "120,", () => AUR_QUERY + "1,");
}

// The CLI rows run TEXTS' bin/vgsh-pkg and bin/vgsh from trees under TMP
// with a PATH of stubs. Answers the failures and the tool a row could not
// run without, or null.
function verifyCli(texts, tmp) {
    const scripts = makeTree(path.join(tmp, "tree"), texts);
    const quick = makeTree(path.join(tmp, "quick"), Object.assign({}, texts, { table: quickTable(texts.table) }));
    const failures = [];
    const counts = { commands: 0, checks: 0, owner: 0 };
    const stubs = path.join(tmp, "stubs");
    const tools = path.join(tmp, "tools");
    fs.mkdirSync(stubs, { recursive: true });
    fs.mkdirSync(tools, { recursive: true });
    for (const command of ["pacman", "yay", "gum", "xbps-install"]) fs.writeFileSync(path.join(stubs, command), "#!/bin/sh\nexit 99\n", { mode: 0o755 });
    // bin/vgsh runs under bash and resolves itself with readlink and
    // dirname; node runs bin/vgsh-pkg, which takes its lock through flock
    // and runs mise's query through env; the stubs use cat and sleep. None
    // of them is a manager.
    for (const tool of ["bash", "readlink", "dirname", "flock", "env", "cat", "sleep"]) {
        const found = childProcess.spawnSync("sh", ["-c", "command -v \"$1\"", "sh", tool], { encoding: "utf8" });
        if (found.status !== 0) return { failures: [], missing: tool, counts };
        const target = path.join(tools, tool);
        if (!fs.existsSync(target)) fs.symlinkSync(found.stdout.trim(), target);
    }
    if (!fs.existsSync(path.join(tools, "node"))) fs.symlinkSync(process.execPath, path.join(tools, "node"));
    const env = { PATH: stubs + path.delimiter + tools, LC_ALL: "C", XDG_RUNTIME_DIR: tmp, HOME: tmp };
    const run = (file, args) => childProcess.spawnSync(file, args, { encoding: "utf8", env });
    const expect = (name, r, status, stdout, stderr) => {
        if (r.status !== status || r.stdout !== stdout || (stderr !== undefined && !r.stderr.startsWith(stderr)))
            failures.push("cli: " + name + ": status=" + r.status + " stdout=" + JSON.stringify(r.stdout) + " stderr=" + JSON.stringify(r.stderr));
    };
    const expectCommand = (...args) => { counts.commands += 1; expect(...args); };
    const expectCheckRow = (...args) => { counts.checks += 1; expect(...args); };
    const expectOwner = (...args) => { counts.owner += 1; expect(...args); };
    expectCommand("present names the missing command and exits 1", run(scripts.pkg, ["present", "gum", "fzf"]), 1, "{\"present\":[\"gum\"],\"missing\":[\"fzf\"]}\n", "");
    expectCommand("present exits 0 when every command is found", run(scripts.pkg, ["present", "gum", "yay"]), 0, "{\"present\":[\"gum\",\"yay\"],\"missing\":[]}\n", "");
    expectCommand("present refuses a path", run(scripts.pkg, ["present", "/bin/sh"]), 2, "", "vgsh: refused: command=\"/bin/sh\"\n");
    expectCommand("plan prints the aur helper's argv", run(scripts.pkg, ["plan", "install", "aur", "gum-bin"]), 0,
        "{\"manager\":\"aur\",\"binary\":\"yay\",\"action\":\"install\",\"elevate\":false,\"steps\":[[\"yay\",\"-S\",\"--needed\",\"--\",\"gum-bin\"]],\"elevator\":null}\n", "");
    expectCommand("plan install without names is a bad invocation", run(scripts.pkg, ["plan", "install", "pacman"]), 2, "", "vgsh: refused: names=missing\n");
    expectCommand("plan upgrade with a name is a bad invocation", run(scripts.pkg, ["plan", "upgrade", "pacman", "gum"]), 2, "", "vgsh: refused: argument=gum\n");
    expectCommand("plan refuses an unknown action", run(scripts.pkg, ["plan", "sync", "pacman"]), 2, "", "vgsh: refused: action=sync\n");
    expectCommand("plan refuses a manager whose binary is absent", run(scripts.pkg, ["plan", "upgrade", "apt"]), 1, "", "vgsh: refused: manager=apt reason=absent binaries=apt-get\n");
    expectCommand("vgsh pkg reaches vgsh-pkg with its arguments", run(scripts.vgsh, ["pkg", "plan", "upgrade", "pacman"]), 0,
        "{\"manager\":\"pacman\",\"binary\":\"pacman\",\"action\":\"upgrade\",\"elevate\":true,\"steps\":[[\"pacman\",\"-Syu\"]],\"elevator\":{\"ok\":false,\"error\":\"elevate=none candidates=sudo,doas,run0\"}}\n", "");
    // The configured elevator over the first on PATH, read as `run` reads it.
    const elevators = path.join(tmp, "elevators");
    fs.mkdirSync(elevators, { recursive: true });
    for (const command of ["sudo", "doas"]) fs.writeFileSync(path.join(elevators, command), "#!/bin/sh\nexit 99\n", { mode: 0o755 });
    const configured = path.join(tmp, "configured");
    fs.mkdirSync(path.join(configured, "vgs"), { recursive: true });
    fs.writeFileSync(path.join(configured, "vgs", "shell.json"), "{ \"packages\": { \"elevate\": \"doas\" } }\n");
    expectCommand("plan names the configured elevator", childProcess.spawnSync(scripts.pkg, ["plan", "upgrade", "pacman"], { encoding: "utf8", env: Object.assign({}, env, { PATH: elevators + path.delimiter + env.PATH, XDG_CONFIG_HOME: configured }) }), 0,
        "{\"manager\":\"pacman\",\"binary\":\"pacman\",\"action\":\"upgrade\",\"elevate\":true,\"steps\":[[\"pacman\",\"-Syu\"]],\"elevator\":{\"ok\":true,\"command\":\"doas\"}}\n", "");

    // detect reads /etc/os-release, so a fixture is bound over it in a
    // private mount namespace. It names Void, so a run that read the
    // machine's own file instead passes only on a Void machine.
    checkRows(scripts, quick, tools, tmp, expectCheckRow, failures);

    const osRelease = (name, text) => {
        const file = path.join(tmp, name);
        fs.writeFileSync(file, text);
        return file;
    };
    const bound = (file, pathValue, args) => childProcess.spawnSync("unshare", ["-rm", "sh", "-c", "mount --bind \"$1\" /etc/os-release && shift && exec \"$@\"", "sh", file,
        "env", "PATH=" + pathValue, "LC_ALL=C", "XDG_RUNTIME_DIR=" + tmp, "HOME=" + tmp, process.execPath, scripts.pkg, ...args], { encoding: "utf8", env: { PATH: process.env.PATH, LC_ALL: "C" } });
    const probe = childProcess.spawnSync("unshare", ["-rm", "true"], { encoding: "utf8" });
    if (probe.status !== 0) return { failures, missing: "user-namespaces", counts };
    // Each fixture names a system the machine running the suite is unlikely
    // to be, so a run that read the machine's own file instead fails.
    const voidLinux = osRelease("os-release-void", "NAME=\"Void\"\nID=\"void\"\n");
    expectCommand("detect --json reads os-release and PATH", bound(voidLinux, env.PATH, ["detect", "--json"]), 0, "{\"primary\":{\"id\":\"xbps\",\"binary\":\"xbps-install\"},\"overlays\":[],\"sources\":[]}\n", "");
    expectCommand("detect prints one line per manager", bound(voidLinux, env.PATH, ["detect"]), 0, "primary=xbps binary=xbps-install\n", "");
    const gentoo = osRelease("os-release-gentoo", "NAME=Gentoo\nID=gentoo\n");
    const gentooPath = stubPath(tmp, "gentoo", { emerge: "exit 99", flatpak: "cat \"" + path.join(FIXTURES, "flatpak.txt") + "\"" }, tools);
    expectCheck(expectCheckRow, "check without --source checks every detected source, emerge only on demand", bound(gentoo, gentooPath, ["check", "--json"]), [
        { source: "emerge", count: null, packages: [], checkedAt: null, error: "skipped=on-demand" },
        { source: "flatpak", count: 3, packages: [{ name: "org.gnome.Loupe", old: null, new: "stable" }, { name: "org.gnome.Platform", old: null, new: "47" },
            { name: "org.freedesktop.Platform.GL.default", old: null, new: "24.08" }], checkedAt: "<time>", error: null }]);

    // Owner stubs answer as pacman and xbps-query do for one owned file,
    // docs/architecture/packages.md § Queries; any other call exits 99.
    const owned = "/usr/share/vgs/VERSION";
    const ownerPath = stubPath(tmp, "owner", {
        pacman: "case \"$1 $2 $3\" in\n  \"-Qoq " + owned + " \") echo vgs-git ;;\n  \"-Qoq \"*) echo \"error: No package owns $2\" >&2; exit 1 ;;\n" +
            "  \"-Q -- vgs-git\") echo \"vgs-git 0.1.0.r40.gabc1234-1\" ;;\n  *) exit 99 ;;\nesac",
        "xbps-install": "exit 99",
        "xbps-query": "[ \"$1 $2\" = \"-o " + owned + "\" ] || exit 99\necho \"vgs-0.1.0_1: " + owned + "\""
    }, tools);
    const arch = osRelease("os-release-arch", "NAME=\"Arch Linux\"\nID=arch\n");
    const suse = osRelease("os-release-suse", "ID=opensuse-tumbleweed\n");
    expectOwner("owner names the package and its installed version", bound(arch, ownerPath, ["owner", owned]), 0,
        "{\"manager\":\"pacman\",\"package\":\"vgs-git\",\"version\":\"0.1.0.r40.gabc1234\"}\n", "");
    expectOwner("owner reports a null version where the table asks none", bound(voidLinux, ownerPath, ["owner", owned]), 0,
        "{\"manager\":\"xbps\",\"package\":\"vgs\",\"version\":null}\n", "");
    expectOwner("owner refuses a file no package owns, the query's words after the line", bound(arch, ownerPath, ["owner", "/opt/vgs/VERSION"]), 1, "",
        "vgsh: refused: path=/opt/vgs/VERSION reason=unowned manager=pacman exit=1\nerror: No package owns /opt/vgs/VERSION\n");
    expectOwner("owner refuses a system no primary serves", bound(suse, ownerPath, ["owner", owned]), 1, "", "vgsh: refused: manager=none\n");
    expectOwner("owner refuses a relative path", bound(arch, ownerPath, ["owner", "VERSION"]), 1, "", "vgsh: refused: path=\"VERSION\" reason=relative\n");
    expectOwner("owner without a path is a bad invocation", bound(arch, ownerPath, ["owner"]), 2, "", "vgsh: refused: path=missing\n");
    return { failures, missing: null, counts };
}

// A PATH of stub commands under TMP/stubs-NAME, each STUBS body a sh
// script, ahead of TOOLS.
function stubPath(tmp, name, stubs, tools) {
    const dir = path.join(tmp, "stubs-" + name);
    fs.mkdirSync(dir, { recursive: true });
    for (const [command, body] of Object.entries(stubs)) fs.writeFileSync(path.join(dir, command), "#!/bin/sh\n" + body + "\n", { mode: 0o755 });
    return dir + path.delimiter + tools;
}

// A check's JSON, each checkedAt that is an ISO time read as "<time>",
// against WANT, through EXPECT.
function expectCheck(expect, name, r, want) {
    let got = r.stdout;
    try {
        const rows = JSON.parse(r.stdout);
        for (const row of rows)
            if (typeof row.checkedAt === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(row.checkedAt)) row.checkedAt = "<time>";
        got = JSON.stringify(rows) + "\n";
    } catch (e) {
        if (!(e instanceof SyntaxError)) throw e;
    }
    expect(name, Object.assign({}, r, { stdout: got }), 0, JSON.stringify(want) + "\n", "");
}

// The `check` rows, through EXPECT or straight into FAILURES. Each runs
// with its own stubs and runtime directory unless it shares one on purpose.
function checkRows(scripts, quick, tools, tmp, expect, failures) {
    const fixtureOf = name => path.join(FIXTURES, name);
    const home = path.join(tmp, "home");
    fs.mkdirSync(home, { recursive: true });
    const runIn = (runtime, file, pathValue, args, extra) => childProcess.spawnSync(file, args, {
        encoding: "utf8", env: Object.assign({ PATH: pathValue, LC_ALL: "POSIX", XDG_RUNTIME_DIR: runtime, HOME: home }, extra) });
    let rows = 0;
    const fresh = () => {
        const dir = path.join(tmp, "run-" + rows++);
        fs.mkdirSync(dir, { recursive: true });
        return dir;
    };
    const bpf = { name: "bpf", old: "7.2.7-1", new: "7.2.8-1" };
    const pacmanRows = [bpf, { name: "coreutils", old: "9.11-2.1", new: "9.12-2.1" }, { name: "python-cattrs", old: "26.2.0-1", new: "26.2.1-1" },
        { name: "python-dbus", old: "1.4.0-2", new: "1.5.0-1" }, { name: "shellcheck", old: "0.11.0-140", new: "0.11.0-142" },
        { name: "sunshine", old: "2026.922.203725-1", new: "2026.928.163558-1" }];
    const checkupdates = "cat \"" + fixtureOf("checkupdates.txt") + "\"";

    expectCheck(expect, "check --source pacman reads checkupdates", runIn(fresh(), scripts.pkg, stubPath(tmp, "pacman", { pacman: "exit 99", checkupdates }, tools), ["check", "--json", "--source", "pacman"]),
        [{ source: "pacman", count: 6, packages: pacmanRows, checkedAt: "<time>", error: null }]);
    expect("check without --json prints a line per source and package", runIn(fresh(), scripts.pkg, stubPath(tmp, "flatpak-text", { flatpak: "cat \"" + fixtureOf("flatpak.txt") + "\"" }, tools), ["check", "--source", "flatpak"]), 0,
        "source=flatpak count=3\n  org.gnome.Loupe ? -> stable\n  org.gnome.Platform ? -> 47\n  org.freedesktop.Platform.GL.default ? -> 24.08\n", "");
    expectCheck(expect, "yay's exit 1 is no update", runIn(fresh(), scripts.pkg, stubPath(tmp, "yay-none", { yay: "exit 1" }, tools), ["check", "--json", "--source", "aur"]),
        [{ source: "aur", count: 0, packages: [], checkedAt: "<time>", error: null }]);
    expect("a failed query is the source's error", runIn(fresh(), scripts.pkg, stubPath(tmp, "flatpak-fails", { flatpak: "echo partial\ttrue; exit 1" }, tools), ["check", "--source", "flatpak"]), 0,
        "source=flatpak error=exit=1\n", "");
    expectCheck(expect, "an absent checkupdates is the source's error", runIn(fresh(), scripts.pkg, stubPath(tmp, "no-checkupdates", { pacman: "exit 99" }, tools), ["check", "--json", "--source", "pacman"]),
        [{ source: "pacman", count: null, packages: [], checkedAt: "<time>", error: "absent=checkupdates" }]);
    const mise = "[ \"$MISE_MINIMUM_RELEASE_AGE\" = 0 ] && [ \"$*\" = \"outdated --json\" ] && [ \"$PWD\" = \"" + home + "\" ] && [ \"$LC_ALL\" = C ] || exit 7\ncat \"" + fixtureOf("mise.json") + "\"";
    expectCheck(expect, "mise's query runs from $HOME with LC_ALL=C and the cooldown waived", runIn(fresh(), scripts.pkg, stubPath(tmp, "mise", { mise }, tools), ["check", "--json", "--source", "mise"]),
        [{ source: "mise", count: 3, packages: [{ name: "aqua:google-antigravity/antigravity-cli", old: "1.2.11", new: "1.2.12" },
            { name: "claude", old: "2.1.283", new: "2.1.284" }, { name: "npm:vercel", old: "60.1.1", new: "60.1.3" }], checkedAt: "<time>", error: null }]);

    // KILL_GRACE_MS in bin/vgsh-pkg is 5 s, the wait between a group's
    // SIGTERM and its SIGKILL. A stub below that ignores SIGTERM sleeps 15 s,
    // so a run ends near 6 s with the SIGKILL and past 15 s without it; the
    // bound between leaves room for the suite's concurrent controls.
    const SLOW_BOUND_MS = 11000;
    const pause = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
    const alive = group => {
        try {
            process.kill(-group, 0);
            return true;
        } catch (e) {
            if (e.code !== "ESRCH") throw e;
            return false;
        }
    };

    // The query ignores SIGTERM and sleeps in a child that keeps stdout
    // open, so the check ends soon after its one-second timeout only if the
    // whole process group gets SIGKILL a grace later; the sleep outlasts
    // both. It runs in the background beside the stop row below, so the two
    // graces overlap, and a shell records its output and status in files.
    const slowDir = fresh();
    const slowOut = path.join(slowDir, "out");
    const slowStatus = path.join(slowDir, "status");
    const started = Date.now();
    childProcess.spawn("/bin/sh", ["-c", "\"$1\" \"$2\" check --json --source aur > \"$3\"; echo $? > \"$4\"", "sh", process.execPath, quick.pkg, slowOut, slowStatus], {
        stdio: "ignore", env: { PATH: stubPath(tmp, "yay-slow", { yay: "trap '' TERM\nsleep 15" }, tools), LC_ALL: "POSIX", XDG_RUNTIME_DIR: slowDir, HOME: home } }).unref();

    // A check stopped by SIGTERM ends every query before it exits. Two
    // sources are detected by PATH alone, as the stubs hold no primary's
    // binary: flatpak's query exits on SIGTERM, mise's ignores it. Each
    // writes its group's id, then sleeps in a child. The shell below sends
    // SIGTERM once both ids are written, finds the lock still held a second
    // later, while mise's group waits for its SIGKILL, and reports the
    // check's status. The real waits are those writes, that second, the
    // grace, and the groups' end, polled every 20 ms.
    const flatpakGroup = path.join(tmp, "stopped-flatpak");
    const miseGroup = path.join(tmp, "stopped-mise");
    const stopRuntime = fresh();
    const stopScript = "\"$1\" \"$2\" check --json & p=$!\ni=0\n" +
        "while { [ ! -s \"$3\" ] || [ ! -s \"$4\" ]; } && [ $i -lt 250 ]; do sleep 0.02; i=$((i + 1)); done\n" +
        "kill -TERM \"$p\"\nsleep 1\nflock -n -E 75 \"$5\" /bin/sh -c :\nprobe=$?\ncase $probe in 0) echo lock=free ;; 75) echo lock=held ;; *) echo lock=probe-failed-$probe ;; esac\nwait \"$p\"\necho \"status=$?\"";
    const stopStarted = Date.now();
    const stopped = childProcess.spawnSync("/bin/sh", ["-c", stopScript, "sh", process.execPath, scripts.pkg, flatpakGroup, miseGroup, path.join(stopRuntime, "vgs", "pkg-check.lock")], {
        encoding: "utf8", env: { PATH: stubPath(tmp, "stopped", { flatpak: "echo $$ > \"" + flatpakGroup + "\"\nsleep 15", mise: "trap '' TERM\necho $$ > \"" + miseGroup + "\"\nsleep 15" }, tools),
            LC_ALL: "POSIX", XDG_RUNTIME_DIR: stopRuntime, HOME: home } });
    const stopElapsed = Date.now() - stopStarted;
    expect("a stopped check holds the lock until its last query ends, then exits 143", stopped, 0, "lock=held\nstatus=143\n", "");
    if (stopped.stderr !== "") failures.push("cli: the stopped check or its lock probe wrote stderr: " + JSON.stringify(stopped.stderr));
    if (stopElapsed >= SLOW_BOUND_MS) failures.push("cli: a stopped check waited past the grace for a query ignoring SIGTERM: elapsed=" + stopElapsed + "ms");
    // The timed-out check started above; the real wait is its timeout and
    // grace, polled every 20 ms up to the sleep it must cut short.
    const slowDeadline = started + 18000;
    const slowDone = () => fs.existsSync(slowStatus) && /^\d+\n$/.test(fs.readFileSync(slowStatus, "utf8"));
    while (!slowDone() && Date.now() < slowDeadline) pause(20);
    const elapsed = Date.now() - started;
    const slow = slowDone() ? { status: Number(fs.readFileSync(slowStatus, "utf8")), stdout: fs.readFileSync(slowOut, "utf8"), stderr: "" } : { status: null, stdout: "", stderr: "" };
    expectCheck(expect, "a query past its timeout is killed", slow, [{ source: "aur", count: null, packages: [], checkedAt: "<time>", error: "timeout=1" }]);
    if (elapsed >= SLOW_BOUND_MS) failures.push("cli: the timed-out query's process group outlived its timeout and grace: elapsed=" + elapsed + "ms");

    for (const file of [flatpakGroup, miseGroup]) {
        const group = fs.existsSync(file) ? Number(fs.readFileSync(file, "utf8")) : 0;
        if (group <= 0) {
            failures.push("cli: a stopped check's query never wrote its group to " + file);
            continue;
        }
        const until = Date.now() + 2000;
        while (alive(group) && Date.now() < until) pause(20);
        if (alive(group)) {
            failures.push("cli: a check stopped by SIGTERM left its query's group " + group + " running");
            process.kill(-group, "SIGKILL");
        }
    }

    // checkupdates skips its sync only after a successful synced run and
    // while its copy of the databases holds one; the stub names the
    // argument it was given as the package.
    const stamped = stubPath(tmp, "stamp", { pacman: "exit 99", checkupdates: "echo \"run${1:-sync} 1-1 -> 2-1\"" }, tools);
    const db = path.join(tmp, "checkup-db");
    fs.mkdirSync(path.join(db, "sync"), { recursive: true });
    fs.writeFileSync(path.join(db, "sync", "core.db"), "");
    const runtime = fresh();
    const synced = name => [{ source: "pacman", count: 1, packages: [{ name, old: "1-1", new: "2-1" }], checkedAt: "<time>", error: null }];
    expectCheck(expect, "the first check syncs", runIn(runtime, scripts.pkg, stamped, ["check", "--json", "--source", "pacman"], { CHECKUPDATES_DB: db }), synced("runsync"));
    expectCheck(expect, "a check right after a synced one skips the sync", runIn(runtime, scripts.pkg, stamped, ["check", "--json", "--source", "pacman"], { CHECKUPDATES_DB: db }), synced("run-n"));
    expectCheck(expect, "a recent sync with no database copy left syncs again", runIn(runtime, scripts.pkg, stamped, ["check", "--json", "--source", "pacman"], { CHECKUPDATES_DB: path.join(tmp, "no-db") }), synced("runsync"));

    // A second check waits for the lock: a holder takes it, and the stub
    // fails unless the holder has let go before the query runs. The real
    // wait is the holder's one second.
    const locked = fresh();
    const held = path.join(locked, "held");
    const released = path.join(locked, "released");
    fs.mkdirSync(path.join(locked, "vgs"));
    const holder = childProcess.spawn("flock", [path.join(locked, "vgs", "pkg-check.lock"), "sh", "-c", "touch \"$1\"; sleep 1; touch \"$2\"", "sh", held, released], { stdio: "ignore" });
    const deadline = Date.now() + 5000;
    while (!fs.existsSync(held) && Date.now() < deadline) pause(20);
    expectCheck(expect, "a check waits for the one running", runIn(locked, scripts.pkg, stubPath(tmp, "locked", { pacman: "exit 99", checkupdates: "[ -e \"" + released + "\" ] || exit 9\n" + checkupdates }, tools), ["check", "--json", "--source", "pacman"]),
        [{ source: "pacman", count: 6, packages: pacmanRows, checkedAt: "<time>", error: null }]);
    holder.unref();

    const plain = stubPath(tmp, "plain", { pacman: "exit 99" }, tools);
    expect("check refuses an unknown manager", runIn(fresh(), scripts.pkg, plain, ["check", "--source", "zypper"]), 1, "", "vgsh: refused: manager=zypper reason=unknown\n");
    expect("check refuses a manager whose binary is absent", runIn(fresh(), scripts.pkg, plain, ["check", "--source", "apt"]), 1, "", "vgsh: refused: manager=apt reason=absent binaries=apt-get\n");
    expect("check refuses an unknown argument", runIn(fresh(), scripts.pkg, plain, ["check", "--all"]), 2, "", "vgsh: refused: argument=--all\n");
    expect("check refuses without a runtime directory", runIn("", scripts.pkg, plain, ["check", "--source", "pacman"]), 1, "", "vgsh: refused: runtime-dir=unset\n");
}

// Each control removes one rule's behaviour from a copy. A `rule:` copy
// plants a defect in the table and must meet that rule of tableErrors,
// since its plan rows would fail on any edited argv; a `table` copy is
// judged by the whole table suite; a `cli` copy runs the CLI rows from a
// tree whose other files are the repository's own. A sixth column names
// text one of the copy's failures must hold, for a control that proves one
// particular assertion can fail.
const CONTROLS = [
    ["cli", "plan names no elevator", PKG, "elevator: planElevator(r.plan)", "elevator: null", "plan names the configured elevator"],
    ["cli", "owner asks no installed version", PKG, "const version = table.managerRow(id).installed === null ? null : query(", "const version = null && query("],
    ["cli", "present exits 0 with a command missing", PKG, "process.exitCode = missing.length === 0 ? 0 : 1;", "process.exitCode = 0;"],
    ["cli", "vgsh pkg drops its arguments", VGSH, "exec node \"$root/bin/vgsh-pkg\" \"$@\"", "exec node \"$root/bin/vgsh-pkg\""],
    ["cli", "a timed-out query's process group lives on", PKG, "process.kill(-child.pid, signal);", "process.kill(child.pid, signal);"],
    ["cli", "check runs without the lock", PKG, "        holdCheckLock(dir);\n", ""],
    ["cli", "checkupdates always syncs", PKG, "if (Date.now() - fs.statSync(stamp).mtimeMs > FRESH_MS) return false;", "return false;"],
    ["cli", "checkupdates skips its sync with no database copy", PKG, "return fs.readdirSync(path.join(db, \"sync\")).some(name => name.endsWith(\".db\"));", "return true;"],
    ["cli", "a query runs from the caller's directory", PKG, "cwd: process.env.HOME || \"/\",", ""],
    ["cli", "a signalled check exits and leaves its queries running", PKG, "for (const signal of [\"SIGINT\", \"SIGTERM\", \"SIGHUP\"]) process.on(signal, () => stopQueries(signal));", ""],
    ["cli", "a timed-out query that ignores SIGTERM is never killed", PKG, "grace = setTimeout(() => signalGroup(\"SIGKILL\"), KILL_GRACE_MS);", ""],
    ["cli", "a stopped check never kills a query that ignores SIGTERM", PKG, "for (const signalGroup of liveGroups.values()) signalGroup(\"SIGKILL\");", ""],
    ["cli", "a stopped check exits when its first query ends", PKG, "if (stopStatus !== null) {\n                if (liveGroups.size === 0) process.exit(stopStatus);", "if (stopStatus !== null) {\n                process.exit(stopStatus);", "lock=free"],
    ["cli", "a query reads the caller's locale", PKG, "env: Object.assign({}, process.env, { LC_ALL: \"C\" }),", "env: process.env,"]
];
// The texts the CLI rows run: the repository's own, or CONTROLS[INDEX]'s
// copy. `{ texts }`, or `{ error }` when the control's text to replace does
// not occur exactly once.
function cliTexts(index) {
    const texts = { pkg: fs.readFileSync(PKG, "utf8"), vgsh: fs.readFileSync(VGSH, "utf8"), table: fs.readFileSync(TABLE, "utf8") };
    if (index === null) return { texts };
    const [, label, file, needle, replacement] = CONTROLS[index];
    const key = file === PKG ? "pkg" : "vgsh";
    const count = texts[key].split(needle).length - 1;
    if (count !== 1) return { error: label + ": the text to replace occurs " + count + " times, not once" };
    return { texts: Object.assign({}, texts, { [key]: texts[key].replace(needle, () => replacement) }) };
}



// The CLI rows wait on real timeouts and graces, so each CLI run is a child
// process of this suite, started together so the waits overlap:
// `--cli-run real|<control index> <dir>` prints one JSON line
// `{ failures, missing, textError }` for the run, textError null unless the
// control's text to replace does not occur exactly once.
if (process.argv[2] === "--cli-run") {
    const index = process.argv[3] === "real" ? null : Number(process.argv[3]);
    const chosen = cliTexts(index);
    const result = chosen.error !== undefined ? { failures: [], missing: null, counts: null, textError: chosen.error } : Object.assign(verifyCli(chosen.texts, process.argv[4]), { textError: null });
    process.stdout.write(JSON.stringify(result) + "\n");
    process.exit(0);
}

// Run one CLI run as a child in DIR: resolves to `{ failures, missing,
// textError }`, a failure naming the child when it does not print that line.
function cliRun(which, dir) {
    return new Promise(resolve => {
        const child = childProcess.spawn(process.execPath, [__filename, "--cli-run", String(which), dir], { stdio: ["ignore", "pipe", "inherit"] });
        const chunks = [];
        child.stdout.on("data", chunk => chunks.push(chunk));
        child.on("close", (status, signal) => {
            const out = Buffer.concat(chunks).toString("utf8");
            try {
                const result = JSON.parse(out);
                if (status === 0 && Array.isArray(result.failures)) {
                    resolve(result);
                    return;
                }
            } catch (e) {
                if (!(e instanceof SyntaxError)) throw e;
            }
            resolve({ failures: ["cli run " + which + " ended status=" + status + " signal=" + signal + " stdout=" + JSON.stringify(out)], missing: null, counts: null, textError: null });
        });
    });
}

// Resolve every task in TASKS, at most LIMIT at once, in order.
async function limited(tasks, limit) {
    const results = new Array(tasks.length);
    let next = 0;
    const worker = async () => {
        while (next < tasks.length) {
            const i = next++;
            results[i] = await tasks[i]();
        }
    };
    await Promise.all(Array.from({ length: Math.min(limit, tasks.length) }, worker));
    return results;
}

let failed = false;
const report = (label, failures) => {
    for (const f of failures) console.log("  FAIL  " + label + ": " + f);
    if (failures.length > 0) failed = true;
};

async function main() {
    const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "vgsh-pkg-cli-")));
    try {
        const runs = ["real"].concat(CONTROLS.map((_, index) => index));
        const results = await limited(runs.map(which => () => cliRun(which, path.join(tmp, "cli-" + which))), Math.max(4, os.availableParallelism()));
        report("cli", results[0].failures);
        const missing = results[0].missing;
        CONTROLS.forEach((control, i) => {
            const result = results[i + 1];
            const mustHold = control[5];
            if (result.textError !== null) report("control", [result.textError]);
            else if (result.failures.length === 0) report("control", [control[1] + ": the suite passed on a copy without that rule"]);
            else if (mustHold !== undefined && !result.failures.some(f => f.includes(mustHold))) report("control", [control[1] + ": no failure on the copy holds " + JSON.stringify(mustHold)]);
        });
        if (failed) process.exitCode = 1;
        else if (missing !== null) {
            console.log("test-vgsh-pkg-cli: status=not-measured missing=" + missing);
            process.exitCode = 77;
        } else {
            const counts = results[0].counts;
            console.log("test-vgsh-pkg-cli: ok commands=" + counts.commands + " checks=" + counts.checks + " owner=" + counts.owner + " controls=" + CONTROLS.length);
        }
    } finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }
}

main();
