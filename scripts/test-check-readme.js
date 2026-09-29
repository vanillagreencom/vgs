#!/usr/bin/env node
// Controls for scripts/check-readme.js. Every row runs this repository's
// check with `--root` on a scratch copy under its tmp/ of the files the
// check reads: README.md, VERSION, bin/vgsh, install.sh,
// docs/architecture/runtime.md, both Arch PKGBUILDs, and each shipped
// plugin's manifest.json and README.md. The pristine copy passes. Each
// other row plants one defect that reaches one rule in a fresh copy and
// asserts the exit status and every output line. Every edit asserts it
// matched once and changed its file. A release changes VERSION, the
// README's pinned tag and the floor together, so no row reads its
// expectation from this repository's current values: each reads them from
// the copy it edits.
"use strict";
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const repo = path.resolve(__dirname, "..");
const tmp = path.join(repo, "tmp", "test-check-readme." + process.pid);
fs.rmSync(tmp, { recursive: true, force: true });
fs.mkdirSync(tmp, { recursive: true });
process.on("exit", () => fs.rmSync(tmp, { recursive: true, force: true }));

const ENV = { PATH: path.dirname(process.execPath) + ":" + process.env.PATH, LC_ALL: "C", HOME: tmp, TMPDIR: tmp };

const pristine = path.join(tmp, "pristine");
const files = ["README.md", "VERSION", "bin/vgsh", "install.sh", "docs/architecture/runtime.md",
    "packaging/arch/vgs/PKGBUILD", "packaging/arch/vgs-git/PKGBUILD"];
const plugins = fs.readdirSync(path.join(repo, "shell/plugins"))
    .filter(dir => fs.existsSync(path.join(repo, "shell/plugins", dir, "manifest.json"))).sort();
if (plugins.length === 0) throw new Error("plugins: refused: count=0, and the repository always ships some");
for (const dir of plugins) {
    files.push(`shell/plugins/${dir}/manifest.json`);
    if (fs.existsSync(path.join(repo, "shell/plugins", dir, "README.md"))) files.push(`shell/plugins/${dir}/README.md`);
}
for (const rel of files) {
    fs.mkdirSync(path.dirname(path.join(pristine, rel)), { recursive: true });
    fs.copyFileSync(path.join(repo, rel), path.join(pristine, rel));
}

function fresh(name) {
    const dir = path.join(tmp, name);
    fs.cpSync(pristine, dir, { recursive: true });
    return dir;
}

// Replace OLD, which must occur exactly once, in TREE/REL.
function replaceIn(tree, rel, old, replacement) {
    const file = path.join(tree, rel);
    if (fs.lstatSync(file).isSymbolicLink()) throw new Error("replace: refused: symlink=" + file);
    const text = fs.readFileSync(file, "utf8");
    const count = text.split(old).length - 1;
    if (count !== 1) throw new Error(`replace: refused: matches=${count} path=${rel} text=${JSON.stringify(old)}`);
    const changed = text.replace(old, () => replacement);
    if (changed === text) throw new Error("replace: refused: unchanged path=" + rel);
    fs.writeFileSync(file, changed);
}

const read = (tree, rel) => fs.readFileSync(path.join(tree, rel), "utf8");
const version = tree => read(tree, "VERSION").trim();
// The 1-based line of the one README line equal to TEXT, or starting with
// it when PREFIX is set.
function lineOf(tree, text, prefix) {
    const lines = read(tree, "README.md").split("\n");
    const hits = lines.flatMap((line, i) => (prefix ? line.startsWith(text) : line === text) ? [i + 1] : []);
    if (hits.length !== 1) throw new Error(`line: refused: matches=${hits.length} text=${JSON.stringify(text)}`);
    return hits[0];
}
// The 1-based line of the one README line that is COMMAND once a `#`
// comment is removed.
function commandLineOf(tree, command) {
    const lines = read(tree, "README.md").split("\n");
    const hits = lines.flatMap((line, i) => line.replace(/(^|\s)#.*$/, "").trim() === command ? [i + 1] : []);
    if (hits.length !== 1) throw new Error(`command line: refused: matches=${hits.length} command=${JSON.stringify(command)}`);
    return hits[0];
}
// The first non-empty line after `## Install`: the floor paragraph.
function floorLine(tree) {
    const lines = read(tree, "README.md").split("\n");
    for (let i = lineOf(tree, "## Install"); i < lines.length; i++) if (lines[i].trim() !== "") return i + 1;
    throw new Error("floor: refused: no paragraph");
}
const curlLine = (tree, args) => lineOf(tree, "curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vgs/main/install.sh | bash" + args);
const nixPrefix = "nix run github:vanillagreencom/vgs/";
const autostart = tree => /^```lua\n(.*)\n```$/m.exec(read(tree, "README.md"))[1];

const ok = tree => `check-readme: ok commands=${commandLines(tree).length} plugins=${plugins.length}`;
// The command lines of every bash fence under `## Install`, read here from
// the text, independent of the check.
function commandLines(tree) {
    const text = read(tree, "README.md");
    const install = text.slice(text.indexOf("## Install\n"), text.indexOf("\n## ", text.indexOf("## Install\n")));
    return [...install.matchAll(/^```bash\n([\s\S]*?)^```$/gm)]
        .flatMap(m => m[1].split("\n"))
        .map(line => line.replace(/(^|\s)#.*$/, "").trim())
        .filter(line => line !== "");
}

// name | setup(tree) | exit | output lines (a function of the tree) | arguments
const ROWS = [
    ["the committed README passes", () => {}, 0, tree => [ok(tree)]],
    // floor
    ["a raised version floor in bin/vgsh is refused until the README follows", t => {
        const m = /^quickshell +([0-9.]+) /m.exec(read(t, "bin/vgsh"));
        const bumped = m[1].replace(/[0-9]+$/, n => String(Number(n) + 1));
        replaceIn(t, "bin/vgsh", m[0], m[0].replace(m[1], bumped));
    }, 1, tree => [`floor README.md:${floorLine(tree)} tool=quickshell need=${/^quickshell +([0-9.]+) /m.exec(read(tree, "bin/vgsh"))[1]}`]],
    ["a floor sentence without a present tool is refused", t => replaceIn(t, "README.md", ", python3 and git.", " and git."),
        1, tree => [`floor README.md:${floorLine(tree)} tool=python3 need=present`]],
    // command
    ["a command of no channel is refused", t => replaceIn(t, "README.md", "\nyay -S vgs\n", "\nsudo pacman -S vgs\n"),
        1, tree => [`command README.md:${lineOf(tree, "sudo pacman -S vgs", true)} unknown text=sudo pacman -S vgs`]],
    ["an AUR package with no recipe is refused", t => replaceIn(t, "README.md", "\nyay -S vgs\n", "\nyay -S vgs-bin\n"),
        1, tree => [`command README.md:${lineOf(tree, "yay -S vgs-bin", true)} channel=aur package=vgs-bin reason=no-recipe`]],
    ["a curl option install.sh no longer parses is refused", t => replaceIn(t, "install.sh", "      --git | --uninstall)", "      --git)"),
        1, tree => [`command README.md:${curlLine(tree, " -s -- --uninstall")} channel=curl option=--uninstall reason=not-in-install.sh`]],
    ["a VERSION bump without the README's pinned commands is refused", t => {
        const v = version(t);
        replaceIn(t, "VERSION", v, v.replace(/[0-9]+$/, n => String(Number(n) + 1)));
    }, 1, tree => {
        const pinned = "v" + /--version v(\S+)/.exec(read(tree, "README.md"))[1];
        return [`command README.md:${curlLine(tree, " -s -- --version " + pinned)} channel=curl version=${pinned} want=v${version(tree)}`,
            `command README.md:${lineOf(tree, nixPrefix, true)} channel=nix tag=${pinned} want=v${version(tree)}`];
    }],
    ["a vgsh command the usage header does not list is refused", t => replaceIn(t, "README.md", "vgs/bin/vgsh run", "vgs/bin/vgsh start"),
        1, tree => [`command README.md:${lineOf(tree, "vgs/bin/vgsh start")} vgsh-command=start reason=not-in-usage`]],
    ["an Install section with no command is refused", t => {
        const text = read(t, "README.md");
        const install = text.slice(text.indexOf("## Install\n"), text.indexOf("\n## ", text.indexOf("## Install\n")));
        replaceIn(t, "README.md", install, install.replace(/^```bash$/gm, "```text"));
    }, 1, tree => [`command README.md:${lineOf(tree, "## Install")} count=0`]],
    // autostart
    ["a README autostart line that drifted is refused", t => replaceIn(t, "README.md", 'hl.exec_cmd("vgsh run")', 'hl.exec_cmd("vgsh run --planted")'),
        1, tree => {
            const n = lineOf(tree, autostart(tree));
            const want = autostart(pristine);
            return [`autostart README.md:${n} differs=docs/architecture/runtime.md want=${want}`, `autostart README.md:${n} differs=install.sh want=${want}`];
        }],
    ["a runtime.md autostart line the README does not follow is refused", t => replaceIn(t, "docs/architecture/runtime.md", 'hl.exec_cmd("vgsh run")', 'hl.exec_cmd("vgsh run --planted")'),
        1, tree => [`autostart README.md:${lineOf(tree, autostart(tree))} differs=docs/architecture/runtime.md want=${autostart(tree).replace('"vgsh run"', '"vgsh run --planted"')}`]],
    ["an install.sh autostart line the README does not follow is refused", t => replaceIn(t, "install.sh", 'hl.exec_cmd("%s run")', 'hl.exec_cmd("%s run --planted")'),
        1, tree => [`autostart README.md:${lineOf(tree, autostart(tree))} differs=install.sh want=${autostart(tree).replace('"vgsh run"', '"vgsh run --planted"')}`]],
    // plugin
    ["a new plugin with no Shipped plugins row is refused", t => {
        fs.mkdirSync(path.join(t, "shell/plugins/vgs.planted"));
        fs.writeFileSync(path.join(t, "shell/plugins/vgs.planted/manifest.json"), "{}\n");
    }, 1, tree => [`plugin README.md:${lineOf(tree, "## Shipped plugins")} missing=shell/plugins/vgs.planted`]],
    ["a row naming a missing plugin is refused", t => replaceIn(t, "README.md", "(shell/plugins/vgs.gallery/README.md)", "(shell/plugins/vgs.gone/README.md)"),
        1, tree => [`plugin README.md:${lineOf(tree, "| [Gallery](shell/plugins/vgs.gone/README.md)", true)} link=shell/plugins/vgs.gone/README.md reason=not-a-plugin`,
            `plugin README.md:${lineOf(tree, "## Shipped plugins")} missing=shell/plugins/vgs.gallery`]],
    ["a row whose link target is gone is refused", t => fs.rmSync(path.join(t, "shell/plugins/vgs.bar/README.md")),
        1, tree => [`plugin README.md:${lineOf(tree, "| [Bar](", true)} link=shell/plugins/vgs.bar/README.md reason=missing-target`]],
    ["a second row for one plugin is refused", t => {
        const row = read(t, "README.md").split("\n").find(line => line.startsWith("| [Bar]("));
        replaceIn(t, "README.md", row + "\n", row + "\n" + row.replace("| [Bar](", "| [Bar again](") + "\n");
    }, 1, tree => [`plugin README.md:${lineOf(tree, "| [Bar again](", true)} duplicate=shell/plugins/vgs.bar first=${lineOf(tree, "| [Bar](", true)}`]],
    // licence
    ["a recipe licence the README does not state is refused", t => {
        const m = /^license=\('([^']+)'\)$/m.exec(read(t, "packaging/arch/vgs/PKGBUILD"));
        replaceIn(t, "packaging/arch/vgs/PKGBUILD", m[0], "license=('MIT')");
    }, 1, tree => {
        const have = /The package licence is `([^`]+)`/.exec(read(tree, "README.md"))[1];
        return [`licence README.md:${lineOf(tree, "VGS is under the MIT licence", true)} have=${have} want=MIT`];
    }],
    // section
    ["a README without its Licence heading is refused", t => replaceIn(t, "README.md", "\n## Licence\n", "\n## License\n"),
        1, () => ["section README.md:1 missing=## Licence"]],
    // --commands, the lines scripts/readme-install.sh reads
    ["--commands prints each command's channel, needs and vgsh arguments", () => {}, 0, tree => {
        const v = "v" + version(tree);
        const curl = "curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vgs/main/install.sh | bash";
        const want = {
            "yay -S vgs": ["aur", "aur:vgs", null],
            "yay -S vgs-git": ["aur", "aur:vgs-git", null],
            [curl]: ["curl", "release:" + v, null],
            [`${curl} -s -- --version ${v}`]: ["curl", "release:" + v, null],
            [`${curl} -s -- --git`]: ["curl", "none", null],
            [`${curl} -s -- --uninstall`]: ["curl", "none", null],
            [`nix run github:vanillagreencom/vgs/${v} -- run`]: ["nix", "release:" + v, "run"],
            "git clone https://github.com/vanillagreencom/vgs": ["checkout", "none", null],
            "vgs/bin/vgsh run": ["checkout", "none", "run"],
        };
        const commands = commandLines(tree);
        if (commands.length !== Object.keys(want).length) throw new Error("commands: refused: README holds a command this row does not name");
        return commands.map(command => {
            if (want[command] === undefined) throw new Error("commands: refused: unnamed=" + command);
            const [channel, needs, vgsh] = want[command];
            return JSON.stringify({ line: commandLineOf(tree, command), channel, needs, vgsh, command });
        });
    }, ["--commands"]],
    ["an install.sh without its argument loop is unreadable", t => replaceIn(t, "install.sh", '  while (($# > 0)); do\n    case "$1" in\n', "  for arg; do\n    case \"$arg\" in\n"),
        2, () => ["check-readme: unreadable: install.sh: no --version arm in the argument loop, so the reader is broken"]],
    ["an unknown argument is refused", () => {}, 2, () => ["check-readme: refused: argument=--bogus"], ["--bogus"]],
];

let failures = 0;
ROWS.forEach(([name, setup, wantExit, wantLines, args], i) => {
    let out = "";
    try {
        const tree = i === 0 ? pristine : fresh("row-" + i);
        setup(tree);
        const run = childProcess.spawnSync(process.execPath, [path.join(repo, "scripts/check-readme.js"), "--root", tree, ...(args || [])], { encoding: "utf8", env: ENV });
        out = run.stdout + run.stderr;
        let have = run.stdout.split("\n").filter(line => line !== "");
        const want = wantLines(tree);
        // --commands lines: every line parses, and block is the count of
        // bash fences opened at or before the command's line.
        if (args !== undefined && args[0] === "--commands") {
            const readme = read(tree, "README.md").split("\n");
            have = have.map(line => {
                const parsed = JSON.parse(line);
                const fences = readme.slice(0, parsed.line - 1).filter(text => text === "```bash").length;
                if (parsed.block !== fences) return "block=" + parsed.block + " want=" + fences + " line=" + parsed.line;
                return JSON.stringify({ line: parsed.line, channel: parsed.channel, needs: parsed.needs, vgsh: parsed.vgsh, command: parsed.command });
            });
        }
        if (run.status === wantExit && have.join("\n") === want.join("\n")) {
            console.log("  ok    " + name);
            return;
        }
        console.log(`  FAIL  ${name}: exit=${run.status} want=${wantExit}\n        have=${JSON.stringify(have)}\n        want=${JSON.stringify(want)}`);
    } catch (e) {
        console.log(`  FAIL  ${name}: ${e.message}`);
    }
    failures += 1;
    if (out !== "") console.log(out.replace(/^/gm, "        "));
});
if (failures > 0) {
    console.log("test-check-readme: failed=" + failures);
    process.exit(1);
}
console.log("test-check-readme: ok");
