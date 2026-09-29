#!/usr/bin/env node
// The package-manager table, shell/Core/PackageManagers.js, and its CLI,
// bin/vgsh-pkg with the `vgsh pkg` verb (D034). Every expected value below
// was written by hand from the managers' own argv, never read from the table.
//
// - The shipped table is judged: unique ids, known roles and placeholders,
//   no step names an elevation command, and no pacman-family step refreshes
//   the databases without upgrading (`-Sy` alone).
// - Detection runs over os-release texts and sets of commands on PATH.
// - Plans pin each manager's argv for install, remove and upgrade.
// - packageFor picks a requirement's package for a detected system.
// - The CLI runs with a PATH of stub commands; `detect` reads a fixture
//   os-release bound over /etc/os-release under `unshare -rm`. Without user
//   namespaces those rows cannot run and the suite exits 77.
//
// The controls at the end edit a copy of the table, bin/vgsh-pkg or
// bin/vgsh, one rule at a time, and require this suite to fail on each copy.
"use strict";
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { load } = require("../bin/lib/qml-library.js");

const repo = path.join(__dirname, "..");
const TABLE = path.join(repo, "shell", "Core", "PackageManagers.js");
const PKG = path.join(repo, "bin", "vgsh-pkg");
const VGSH = path.join(repo, "bin", "vgsh");
const ELEVATORS = ["sudo", "doas", "run0", "pkexec", "su"];
const PLACEHOLDERS = ["{bin}", "{names}", "{path}"];
const EXIT_MEANINGS = ["updates", "none", "rows"];

// The table's own defects, one string each; empty for a sound table.
function tableErrors(t) {
    const errors = [];
    const ids = t.MANAGERS.map(row => row.id);
    if (t.MANAGERS.length < 9) errors.push("table: fewer than the nine managers D034 names; the loader read no table");
    if (new Set(ids).size !== ids.length) errors.push("ids: not unique");
    for (const row of t.MANAGERS) {
        const where = "manager " + row.id;
        if (!["primary", "overlay", "source"].includes(row.role)) errors.push(where + ": role " + row.role);
        if ((row.role === "primary") !== (row.family.length > 0)) errors.push(where + ": a family belongs to a primary alone");
        if (row.requires !== null && !t.MANAGERS.some(o => o.id === row.requires && o.role === "primary")) errors.push(where + ": requires names no primary");
        if (row.binaries.length === 0) errors.push(where + ": no binary");
        const pacmanFamily = row.binaries.some(b => ["pacman", "paru", "yay"].includes(b));
        const templates = [];
        for (const action of t.ACTIONS) if (row[action] !== null) for (const step of row[action]) templates.push([action, step]);
        if (row.owner !== null) templates.push(["owner", row.owner]);
        if (row.check !== null) {
            templates.push(["check", row.check.argv]);
            for (const [code, meaning] of Object.entries(row.check.exits))
                if (!/^[0-9]+$/.test(code) || !EXIT_MEANINGS.includes(meaning)) errors.push(where + ": check exit " + code + "=" + meaning);
        }
        for (const [action, step] of templates) {
            if (step.length === 0) errors.push(where + " " + action + ": empty step");
            for (const token of step) {
                if (token.startsWith("{") && !PLACEHOLDERS.includes(token)) errors.push(where + " " + action + ": placeholder " + token);
                if (ELEVATORS.includes(token)) errors.push(where + " " + action + ": elevation command " + token);
                if (pacmanFamily && /^-[A-Za-z]*S[A-Za-z]*$/.test(token) && token.includes("y") && !token.includes("u"))
                    errors.push(where + " " + action + ": partial upgrade " + token);
            }
            const names = step.filter(token => token === "{names}").length;
            if (action === "install" || action === "remove") { if (names > 1) errors.push(where + " " + action + ": {names} twice"); }
            else if (names > 0) errors.push(where + " " + action + ": {names} outside install and remove");
            if (step.includes("{path}") !== (action === "owner")) errors.push(where + " " + action + ": {path} belongs to the owner query");
        }
        for (const action of ["install", "remove"])
            if (row[action] !== null && !row[action].some(step => step.includes("{names}"))) errors.push(where + " " + action + ": no step takes the names");
    }
    return errors;
}

// Detection rows: name, os-release text, the commands on PATH, the answer.
const pacman = { id: "pacman", binary: "pacman" };
const DETECT_ROWS = [
    ["Arch with paru, flatpak and mise", "NAME=\"Arch Linux\"\nID=arch\n", ["pacman", "paru", "flatpak", "mise"],
        { primary: pacman, overlays: [{ id: "aur", binary: "paru" }, { id: "flatpak", binary: "flatpak" }], sources: [{ id: "mise", binary: "mise" }] }],
    ["an Arch derivative through ID_LIKE, with yay", "ID=cachyos\nID_LIKE=arch\n", ["pacman", "yay"],
        { primary: pacman, overlays: [{ id: "aur", binary: "yay" }], sources: [] }],
    ["paru is preferred to yay", "ID=endeavouros\nID_LIKE=arch\n", ["pacman", "yay", "paru"],
        { primary: pacman, overlays: [{ id: "aur", binary: "paru" }], sources: [] }],
    ["Ubuntu through its own ID", "ID=ubuntu\nID_LIKE=debian\n", ["apt-get", "flatpak"],
        { primary: { id: "apt", binary: "apt-get" }, overlays: [{ id: "flatpak", binary: "flatpak" }], sources: [] }],
    ["an Ubuntu derivative through a quoted ID_LIKE list", "ID=linuxmint\nID_LIKE=\"ubuntu debian\"\n", ["apt-get"],
        { primary: { id: "apt", binary: "apt-get" }, overlays: [], sources: [] }],
    ["Fedora prefers dnf5; an AUR helper without pacman is no overlay", "ID=fedora\n", ["dnf5", "dnf", "paru"],
        { primary: { id: "dnf", binary: "dnf5" }, overlays: [], sources: [] }],
    ["a Fedora derivative with dnf alone", "ID=\"rocky\"\nID_LIKE=\"rhel centos fedora\"\n", ["dnf"],
        { primary: { id: "dnf", binary: "dnf" }, overlays: [], sources: [] }],
    ["Void", "ID=\"void\"\n", ["xbps-install"], { primary: { id: "xbps", binary: "xbps-install" }, overlays: [], sources: [] }],
    ["Gentoo", "ID=gentoo\n", ["emerge"], { primary: { id: "emerge", binary: "emerge" }, overlays: [], sources: [] }],
    ["NixOS", "ID=nixos\n", ["nix"], { primary: { id: "nix", binary: "nix" }, overlays: [], sources: [] }],
    ["a binary alone makes no primary", "ID=arch\n", ["apt-get"], { primary: null, overlays: [], sources: [] }],
    ["no os-release keeps overlays and sources", "", ["pacman", "paru", "flatpak", "mise"],
        { primary: null, overlays: [{ id: "flatpak", binary: "flatpak" }], sources: [{ id: "mise", binary: "mise" }] }],
    ["an unknown family has no primary", "ID=opensuse-tumbleweed\nID_LIKE=\"opensuse suse\"\n", ["zypper"], { primary: null, overlays: [], sources: [] }],
    ["a single-quoted ID", "ID='arch'\n", ["pacman"], { primary: pacman, overlays: [], sources: [] }],
    ["the last assignment wins; a comment assigns nothing", "# ID=gentoo\nID=debian\nID=arch\n", ["pacman", "apt-get"], { primary: pacman, overlays: [], sources: [] }],
    ["a CRLF file", "ID=arch\r\nNAME=x\r\n", ["pacman"], { primary: pacman, overlays: [], sources: [] }]
];

// os-release identifier rows: name, text, the identifiers in order.
const ID_ROWS = [
    ["ID then each ID_LIKE token", "ID=a\nID_LIKE=\"b  c\"\n", ["a", "b", "c"]],
    ["an escaped quote inside double quotes", "ID=\"a\\\"b\"\n", ["a\"b"]],
    ["ID_LIKE without ID", "ID_LIKE=arch\n", ["arch"]],
    ["an empty file", "", []]
];

// Plan rows: name, manager, action, names, the commands on PATH, and the
// plan's binary, elevate and steps, or the refusal's first line.
const PLAN_ROWS = [
    ["pacman install", "pacman", "install", ["gum", "fzf"], ["pacman"], { binary: "pacman", elevate: true, steps: [["pacman", "-S", "--needed", "--", "gum", "fzf"]] }],
    ["pacman remove", "pacman", "remove", ["gum"], ["pacman"], { binary: "pacman", elevate: true, steps: [["pacman", "-Rns", "--", "gum"]] }],
    ["pacman upgrade is a full -Syu", "pacman", "upgrade", [], ["pacman"], { binary: "pacman", elevate: true, steps: [["pacman", "-Syu"]] }],
    ["aur install through paru", "aur", "install", ["gum-bin"], ["paru", "yay"], { binary: "paru", elevate: false, steps: [["paru", "-S", "--needed", "--", "gum-bin"]] }],
    ["aur install through yay", "aur", "install", ["gum-bin"], ["yay"], { binary: "yay", elevate: false, steps: [["yay", "-S", "--needed", "--", "gum-bin"]] }],
    ["aur remove", "aur", "remove", ["gum-bin"], ["paru"], { binary: "paru", elevate: false, steps: [["paru", "-Rns", "--", "gum-bin"]] }],
    ["aur upgrade", "aur", "upgrade", [], ["paru"], { binary: "paru", elevate: false, steps: [["paru", "-Sua"]] }],
    ["apt install", "apt", "install", ["gum"], ["apt-get"], { binary: "apt-get", elevate: true, steps: [["apt-get", "install", "gum"]] }],
    ["apt remove", "apt", "remove", ["gum"], ["apt-get"], { binary: "apt-get", elevate: true, steps: [["apt-get", "remove", "gum"]] }],
    ["apt upgrade refreshes, then upgrades", "apt", "upgrade", [], ["apt-get"], { binary: "apt-get", elevate: true, steps: [["apt-get", "update"], ["apt-get", "full-upgrade"]] }],
    ["dnf install through dnf5", "dnf", "install", ["gum"], ["dnf5", "dnf"], { binary: "dnf5", elevate: true, steps: [["dnf5", "install", "gum"]] }],
    ["dnf remove through dnf", "dnf", "remove", ["gum"], ["dnf"], { binary: "dnf", elevate: true, steps: [["dnf", "remove", "gum"]] }],
    ["dnf upgrade", "dnf", "upgrade", [], ["dnf"], { binary: "dnf", elevate: true, steps: [["dnf", "upgrade"]] }],
    ["xbps install", "xbps", "install", ["gum"], ["xbps-install"], { binary: "xbps-install", elevate: true, steps: [["xbps-install", "-S", "gum"]] }],
    ["xbps remove", "xbps", "remove", ["gum"], ["xbps-install"], { binary: "xbps-install", elevate: true, steps: [["xbps-remove", "-R", "gum"]] }],
    ["xbps upgrade", "xbps", "upgrade", [], ["xbps-install"], { binary: "xbps-install", elevate: true, steps: [["xbps-install", "-Su"]] }],
    ["emerge install", "emerge", "install", ["app-misc/gum"], ["emerge"], { binary: "emerge", elevate: true, steps: [["emerge", "--ask", "--noreplace", "app-misc/gum"]] }],
    ["emerge remove", "emerge", "remove", ["app-misc/gum"], ["emerge"], { binary: "emerge", elevate: true, steps: [["emerge", "--ask", "--depclean", "app-misc/gum"]] }],
    ["emerge upgrade syncs, then updates the world set", "emerge", "upgrade", [], ["emerge"], { binary: "emerge", elevate: true, steps: [["emerge", "--sync"], ["emerge", "--ask", "--update", "--deep", "--newuse", "@world"]] }],
    ["flatpak install", "flatpak", "install", ["org.gnome.Loupe"], ["flatpak"], { binary: "flatpak", elevate: false, steps: [["flatpak", "install", "org.gnome.Loupe"]] }],
    ["flatpak remove", "flatpak", "remove", ["org.gnome.Loupe"], ["flatpak"], { binary: "flatpak", elevate: false, steps: [["flatpak", "uninstall", "org.gnome.Loupe"]] }],
    ["flatpak upgrade", "flatpak", "upgrade", [], ["flatpak"], { binary: "flatpak", elevate: false, steps: [["flatpak", "update"]] }],
    ["mise install", "mise", "install", ["npm:@anthropic-ai/claude-code"], ["mise"], { binary: "mise", elevate: false, steps: [["mise", "use", "--global", "npm:@anthropic-ai/claude-code"]] }],
    ["mise remove", "mise", "remove", ["node"], ["mise"], { binary: "mise", elevate: false, steps: [["mise", "unuse", "--global", "node"]] }],
    ["mise upgrade waives the release-age cooldown", "mise", "upgrade", [], ["mise"], { binary: "mise", elevate: false, steps: [["env", "MISE_MINIMUM_RELEASE_AGE=0", "mise", "upgrade"]] }],
    ["nix install is unsupported", "nix", "install", ["gum"], ["nix"], "manager=nix action=install reason=unsupported"],
    ["nix remove is unsupported", "nix", "remove", ["gum"], ["nix"], "manager=nix action=remove reason=unsupported"],
    ["nix upgrade is unsupported", "nix", "upgrade", [], ["nix"], "manager=nix action=upgrade reason=unsupported"],
    ["an unknown manager", "zypper", "install", ["gum"], ["zypper"], "manager=zypper reason=unknown"],
    ["a manager whose binary is absent", "dnf", "install", ["gum"], [], "manager=dnf reason=absent binaries=dnf5,dnf"],
    ["a name that starts with a dash", "pacman", "install", ["-Sy"], ["pacman"], "name=\"-Sy\" reason=grammar"],
    ["a name with a space", "pacman", "install", ["gum fzf"], ["pacman"], "name=\"gum fzf\" reason=grammar"],
    ["an empty name", "pacman", "install", [""], ["pacman"], "name=\"\" reason=grammar"],
    ["a name past 256 characters", "pacman", "install", ["a".repeat(257)], ["pacman"], "name=\"" + "a".repeat(257) + "\" reason=grammar"]
];

// packageFor rows: name, a requirement's packages, detect's answer, the pick.
const PACMAN = { id: "pacman", binary: "pacman" };
const PARU = { id: "aur", binary: "paru" };
const MISE = { id: "mise", binary: "mise" };
const PACKAGE_FOR_ROWS = [
    ["the primary's package wins over an overlay's", { aur: "gum-bin", pacman: "gum" }, { primary: PACMAN, overlays: [PARU], sources: [] }, { manager: "pacman", name: "gum" }],
    ["an overlay serves what the primary does not map", { aur: "vsys" }, { primary: PACMAN, overlays: [PARU], sources: [] }, { manager: "aur", name: "vsys" }],
    ["an overlay wins over a source", { mise: "node", aur: "nodejs-bin" }, { primary: PACMAN, overlays: [PARU], sources: [MISE] }, { manager: "aur", name: "nodejs-bin" }],
    ["a source serves last", { mise: "node" }, { primary: PACMAN, overlays: [], sources: [MISE] }, { manager: "mise", name: "node" }],
    ["an overlay serves a system with no primary", { flatpak: "org.gnome.Loupe" }, { primary: null, overlays: [{ id: "flatpak", binary: "flatpak" }], sources: [] }, { manager: "flatpak", name: "org.gnome.Loupe" }],
    ["no present manager is mapped", { apt: "gum", dnf: "gum" }, { primary: PACMAN, overlays: [PARU], sources: [] }, null],
    ["no package is mapped at all", {}, { primary: PACMAN, overlays: [], sources: [] }, null]
];

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function verifyTable(t) {
    const failures = tableErrors(t);
    const onPathOf = list => command => list.includes(command);
    for (const [name, text, commands, want] of DETECT_ROWS) {
        const got = t.detect(t.osReleaseIds(text), onPathOf(commands));
        if (!same(got, want)) failures.push("detect: " + name + ": got " + JSON.stringify(got));
    }
    for (const [name, text, want] of ID_ROWS) {
        const got = t.osReleaseIds(text);
        if (!same(got, want)) failures.push("os-release: " + name + ": got " + JSON.stringify(got));
    }
    const covered = new Set();
    for (const [name, manager, action, names, commands, want] of PLAN_ROWS) {
        const got = t.plan(manager, action, names, onPathOf(commands));
        const expected = typeof want === "string" ? { ok: false, error: want } : { ok: true, plan: { manager, binary: want.binary, action, elevate: want.elevate, steps: want.steps } };
        if (!same(got, expected)) failures.push("plan: " + name + ": got " + JSON.stringify(got));
        covered.add(manager + " " + action);
    }
    for (const row of t.MANAGERS) for (const action of t.ACTIONS)
        if (!covered.has(row.id + " " + action)) failures.push("plan: no row for " + row.id + " " + action);
    for (const [name, packages, found, want] of PACKAGE_FOR_ROWS) {
        const got = t.packageFor(packages, found);
        if (!same(got, want)) failures.push("packageFor: " + name + ": got " + JSON.stringify(got));
    }
    return failures;
}

// The CLI rows run SCRIPTS' bin/vgsh-pkg and bin/vgsh with a PATH of stubs.
// Each returns a failure string or null.
function verifyCli(scripts, tmp) {
    const failures = [];
    const stubs = path.join(tmp, "stubs");
    const tools = path.join(tmp, "tools");
    fs.mkdirSync(stubs, { recursive: true });
    fs.mkdirSync(tools, { recursive: true });
    for (const command of ["pacman", "yay", "gum", "xbps-install"]) fs.writeFileSync(path.join(stubs, command), "#!/bin/sh\nexit 99\n", { mode: 0o755 });
    // bin/vgsh runs under bash and resolves itself with readlink and
    // dirname; node runs bin/vgsh-pkg. None of them is a manager.
    for (const tool of ["bash", "readlink", "dirname"]) {
        const found = childProcess.spawnSync("sh", ["-c", "command -v \"$1\"", "sh", tool], { encoding: "utf8" });
        if (found.status !== 0) return { failures: [], missing: tool };
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
    expect("present names the missing command and exits 1", run(scripts.pkg, ["present", "gum", "fzf"]), 1, "{\"present\":[\"gum\"],\"missing\":[\"fzf\"]}\n", "");
    expect("present exits 0 when every command is found", run(scripts.pkg, ["present", "gum", "yay"]), 0, "{\"present\":[\"gum\",\"yay\"],\"missing\":[]}\n", "");
    expect("present refuses a path", run(scripts.pkg, ["present", "/bin/sh"]), 2, "", "vgsh: refused: command=\"/bin/sh\"\n");
    expect("plan prints the aur helper's argv", run(scripts.pkg, ["plan", "install", "aur", "gum-bin"]), 0,
        "{\"manager\":\"aur\",\"binary\":\"yay\",\"action\":\"install\",\"elevate\":false,\"steps\":[[\"yay\",\"-S\",\"--needed\",\"--\",\"gum-bin\"]]}\n", "");
    expect("plan install without names is a bad invocation", run(scripts.pkg, ["plan", "install", "pacman"]), 2, "", "vgsh: refused: names=missing\n");
    expect("plan upgrade with a name is a bad invocation", run(scripts.pkg, ["plan", "upgrade", "pacman", "gum"]), 2, "", "vgsh: refused: argument=gum\n");
    expect("plan refuses an unknown action", run(scripts.pkg, ["plan", "sync", "pacman"]), 2, "", "vgsh: refused: action=sync\n");
    expect("plan refuses a manager whose binary is absent", run(scripts.pkg, ["plan", "upgrade", "apt"]), 1, "", "vgsh: refused: manager=apt reason=absent binaries=apt-get\n");
    expect("vgsh pkg reaches vgsh-pkg with its arguments", run(scripts.vgsh, ["pkg", "plan", "upgrade", "pacman"]), 0,
        "{\"manager\":\"pacman\",\"binary\":\"pacman\",\"action\":\"upgrade\",\"elevate\":true,\"steps\":[[\"pacman\",\"-Syu\"]]}\n", "");

    // detect reads /etc/os-release, so a fixture is bound over it in a
    // private mount namespace. It names Void, so a run that read the
    // machine's own file instead passes only on a Void machine.
    const fixture = path.join(tmp, "os-release");
    fs.writeFileSync(fixture, "NAME=\"Void\"\nID=\"void\"\n");
    const bound = args => childProcess.spawnSync("unshare", ["-rm", "sh", "-c", "mount --bind \"$1\" /etc/os-release && PATH=\"$2\" exec \"$3\" \"$4\" detect $5", "sh", fixture, env.PATH, process.execPath, scripts.pkg, args], { encoding: "utf8", env: { PATH: process.env.PATH, LC_ALL: "C" } });
    const probe = childProcess.spawnSync("unshare", ["-rm", "true"], { encoding: "utf8" });
    if (probe.status !== 0) return { failures, missing: "user-namespaces" };
    expect("detect --json reads os-release and PATH", bound("--json"), 0, "{\"primary\":{\"id\":\"xbps\",\"binary\":\"xbps-install\"},\"overlays\":[],\"sources\":[]}\n", "");
    expect("detect prints one line per manager", bound(""), 0, "primary=xbps binary=xbps-install\n", "");
    return { failures, missing: null };
}

let failed = false;
const report = (label, failures) => {
    for (const f of failures) console.log("  FAIL  " + label + ": " + f);
    if (failures.length > 0) failed = true;
};

const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "vgsh-pkg-")));
let missing = null;
try {
    report("table", verifyTable(load(TABLE)));
    const cli = verifyCli({ pkg: PKG, vgsh: VGSH }, path.join(tmp, "real"));
    report("cli", cli.failures);
    missing = cli.missing;

    // Each control removes one rule's behaviour from a copy. A `rule:` copy
    // plants a defect in the table and must meet that rule of tableErrors,
    // since its plan rows would fail on any edited argv; a `table` copy is
    // judged by the whole table suite; a `cli` copy runs from a tree whose
    // other files are the repository's own.
    const CONTROLS = [
        ["rule:partial upgrade", "a pacman upgrade refreshes without upgrading", TABLE, "upgrade: [[\"{bin}\", \"-Syu\"]],", "upgrade: [[\"{bin}\", \"-Sy\"]],"],
        ["rule:elevation command", "a step elevates", TABLE, "[\"{bin}\", \"full-upgrade\"]", "[\"sudo\", \"{bin}\", \"full-upgrade\"]"],
        ["table", "ID_LIKE is ignored", TABLE, "    if (like !== null) {", "    if (false) {"],
        ["table", "an overlay ignores the primary it requires", TABLE, "if (other.requires !== null && (primary === null || primary.id !== other.requires)) continue;", ""],
        ["table", "a name may start with a dash", TABLE, " && name.charAt(0) !== \"-\"", ""],
        ["table", "the first binary wins even when absent", TABLE, "if (onPath(row.binaries[i])) return row.binaries[i];", "return row.binaries[i];"],
        ["table", "a requirement's package ignores the primary's rank", TABLE, "var order = (found.primary === null ? [] : [found.primary]).concat(found.overlays, found.sources);", "var order = found.overlays.concat(found.sources, found.primary === null ? [] : [found.primary]);"],
        ["table", "a requirement's package is picked for an unmapped manager", TABLE, "if (Object.prototype.hasOwnProperty.call(packages, order[i].id))", "if (true)"],
        ["cli", "present exits 0 with a command missing", PKG, "process.exitCode = missing.length === 0 ? 0 : 1;", "process.exitCode = 0;"],
        ["cli", "vgsh pkg drops its arguments", VGSH, "exec node \"$root/bin/vgsh-pkg\" \"$@\"", "exec node \"$root/bin/vgsh-pkg\""]
    ];
    const tree = path.join(tmp, "tree");
    fs.mkdirSync(path.join(tree, "bin"), { recursive: true });
    fs.mkdirSync(path.join(tree, "shell", "Core"), { recursive: true });
    fs.symlinkSync(path.join(repo, "bin", "lib"), path.join(tree, "bin", "lib"));
    fs.symlinkSync(TABLE, path.join(tree, "shell", "Core", "PackageManagers.js"));
    CONTROLS.forEach(([kind, label, file, needle, replacement], index) => {
        const source = fs.readFileSync(file, "utf8");
        const count = source.split(needle).length - 1;
        if (count !== 1) { report("control", [label + ": the text to replace occurs " + count + " times, not once"]); return; }
        const mutated = source.replace(needle, () => replacement);
        let failures;
        if (kind !== "cli") {
            const mutant = path.join(tmp, index + "-PackageManagers.js");
            fs.writeFileSync(mutant, mutated);
            failures = kind === "table" ? verifyTable(load(mutant)) : tableErrors(load(mutant)).filter(f => f.includes(kind.slice("rule:".length)));
        } else {
            for (const [name, real] of [["vgsh-pkg", PKG], ["vgsh", VGSH]]) {
                fs.rmSync(path.join(tree, "bin", name), { force: true });
                fs.writeFileSync(path.join(tree, "bin", name), real === file ? mutated : fs.readFileSync(real, "utf8"), { mode: 0o755 });
            }
            failures = verifyCli({ pkg: path.join(tree, "bin", "vgsh-pkg"), vgsh: path.join(tree, "bin", "vgsh") }, path.join(tmp, "control-" + index)).failures;
        }
        if (failures.length === 0) report("control", [label + ": the suite passed on a copy without that rule"]);
    });
    if (failed) process.exitCode = 1;
    else if (missing !== null) {
        console.log("test-vgsh-pkg: status=not-measured missing=" + missing);
        process.exitCode = 77;
    } else console.log("test-vgsh-pkg: ok detect=" + DETECT_ROWS.length + " plans=" + PLAN_ROWS.length + " picks=" + PACKAGE_FOR_ROWS.length + " controls=" + CONTROLS.length);
} finally {
    fs.rmSync(tmp, { recursive: true, force: true });
}
