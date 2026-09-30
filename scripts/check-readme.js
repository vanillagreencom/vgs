#!/usr/bin/env node
// Check README.md's Install, Shipped plugins and Licence sections offline
// against the files they describe.
//
//   node scripts/check-readme.js [--root DIR] [--commands]
//
// DIR, this repository by default, holds the files read: README.md,
// VERSION, bin/vgsh, install.sh, docs/architecture/runtime.md,
// packaging/arch/ and shell/plugins/. bin/vgsh-scan always comes from this
// script's own repository and lists DIR's plugins.
//
// Rules. Each finding is one line, `<rule> README.md:<line> <detail>`:
//   section    README.md has the headings `## Install`, `## Shipped plugins`
//              and `## Licence`. A section runs to the next `## ` heading.
//   floor      the first paragraph of § Install names every row of bin/vgsh's
//              preflight_floor table, read by scripts/preflight-floor.js:
//              `<tool> <need> or later` for a version, the tool's name for
//              `present`, in any case.
//   command    every line of every ```bash fence in § Install, with a `#`
//              comment removed, is one command of one channel:
//                aur       `yay -S <pkg>`, <pkg> a directory under packaging/arch/
//                curl      `curl -fsSL <INSTALL_URL> | bash`, or the same with
//                          `| bash -s -- <options>`: each option one that
//                          install.sh's option parser accepts, and a
//                          --version value `v<VERSION>`
//                nix       `nix run github:vanillagreencom/vgs/v<VERSION> -- <vgsh args>`
//                checkout  `git clone https://github.com/vanillagreencom/vgs`,
//                          or `vgs/bin/vgsh <vgsh args>`
//              <vgsh args> start with a command the usage header of bin/vgsh
//              lists. § Install holds at least one command.
//   autostart  § Install holds one ```lua fence of one line. The line equals
//              the autostart line docs/architecture/runtime.md states, and
//              the line install.sh prints with `vgsh` for its absolute path.
//   plugin     § Shipped plugins has one table row linking into each plugin
//              directory bin/vgsh-scan lists under shell/plugins/, and no
//              row links anywhere else. Each link target exists.
//   licence    § Licence's "The package licence is `<expr>`" equals the
//              license of packaging/arch/vgs/PKGBUILD.
//
// --commands prints, when every rule passes, one JSON line per command:
// { block, line, channel, needs, vgsh, command }. block counts the bash
// fences of § Install from 1. line is the command's line in README.md.
// needs is `release:v<VERSION>` for a curl release install and a nix run,
// `aur:<pkg>` for an AUR install, else `none`: what must be published
// before the command can run. vgsh is the vgsh arguments the command runs,
// else null. scripts/readme-install.sh reads these lines.
//
// Exit 0 prints `check-readme: ok commands=<n> plugins=<n>`, or the JSON
// lines under --commands. Exit 1 prints the findings. Exit 2 prints
// `check-readme: unreadable: <path>: <cause>` for a file that cannot be read
// or holds none of what a rule reads, or `check-readme: refused:
// argument=<arg>` for the first argument it does not take.
"use strict";
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const { parseFloors } = require("./preflight-floor.js");

const codeRoot = path.resolve(__dirname, "..");
const args = process.argv.slice(2);
let root = codeRoot, commandsMode = false;
for (let i = 0; i < args.length; i++) {
    if (args[i] === "--root" && i + 1 < args.length && args[i + 1] !== "") root = path.resolve(args[++i]);
    else if (args[i] === "--commands") commandsMode = true;
    else {
        process.stdout.write("check-readme: refused: argument=" + args[i] + "\n");
        process.exit(2);
    }
}

const README = "README.md";
const INSTALL_URL = "https://raw.githubusercontent.com/vanillagreencom/vgs/main/install.sh";
const CLONE_URL = "https://github.com/vanillagreencom/vgs";

function unreadable(rel, cause) {
    process.stdout.write("check-readme: unreadable: " + rel + ": " + cause + "\n");
    process.exit(2);
}

function readText(rel) {
    try {
        return fs.readFileSync(path.join(root, rel), "utf8");
    } catch (e) {
        return unreadable(rel, e.code || String(e));
    }
}

const findings = [];
function finding(rule, line, detail) {
    findings.push(`${rule} ${README}:${line} ${detail}`);
}

// ---- sources ---------------------------------------------------------------

const version = readText("VERSION").replace(/\n$/, "");
const vgshText = readText("bin/vgsh");

const floors = (() => {
    const read = parseFloors(vgshText);
    if (!read.ok) unreadable("bin/vgsh", read.key + " " + read.detail);
    return read.rows;
})();

// The first word after `vgsh` on each command line of bin/vgsh's usage
// header, the comment block after the shebang.
const vgshCommands = (() => {
    const header = /^#!.*\n((?:#.*\n)+)/.exec(vgshText);
    const names = new Set();
    if (header !== null)
        for (const m of header[1].matchAll(/^#\s+vgsh (\S+)/gm)) names.add(m[1]);
    if (!names.has("run")) unreadable("bin/vgsh", "the usage header lists no `vgsh run`, so the reader is broken");
    return names;
})();

const installText = readText("install.sh");

// The long options of the `case "$1" in` arms inside install.sh's argument
// loop, `while (($# > 0)); do`.
const installOptions = (() => {
    const loop = /^\s*while \(\(\$# > 0\)\); do\n\s*case "\$1" in\n([\s\S]*?)^\s*esac$/m.exec(installText);
    const options = new Set();
    if (loop !== null) {
        for (const arm of loop[1].matchAll(/^\s*([^\s()][^)\n]*)\)/gm))
            for (const alternative of arm[1].split("|").map(text => text.trim()))
                if (/^--[a-z][a-z-]*$/.test(alternative)) options.add(alternative);
    }
    if (!options.has("--version")) unreadable("install.sh", "no --version arm in the argument loop, so the reader is broken");
    return options;
})();

// The autostart line install.sh prints, with `vgsh` for the path it fills.
const installAutostart = (() => {
    const m = /^\s*printf '\s*(hl\.on\([^'\n]*%s run[^'\n]*\))\\n' "\$link"$/m.exec(installText);
    if (m === null) unreadable("install.sh", "no printf of the hl.on autostart line");
    return m[1].replace("%s", "vgsh");
})();

const runtimeAutostart = (() => {
    const rel = "docs/architecture/runtime.md";
    const m = /Autostart is \x60(hl\.on\([^\x60\n]*\))\x60/.exec(readText(rel));
    if (m === null) unreadable(rel, "no `Autostart is `hl.on(...)`` sentence");
    return m[1];
})();

const pkgbuildLicence = (() => {
    const rel = "packaging/arch/vgs/PKGBUILD";
    const m = /^license=\('([^']+)'\)$/m.exec(readText(rel));
    if (m === null) unreadable(rel, "no license=('...') line");
    return m[1];
})();

// Each plugin directory as bin/vgsh-scan lists it, relative to the root.
const pluginDirs = (() => {
    const base = path.join(root, "shell", "plugins");
    const scan = childProcess.spawnSync(path.join(codeRoot, "bin", "vgsh-scan"), ["--require-base", base],
        { encoding: "utf8", env: { PATH: process.env.PATH, LC_ALL: "C" } });
    if (scan.error || scan.status !== 0) unreadable("shell/plugins", "vgsh-scan " + (scan.error ? scan.error.code : "exited " + scan.status) + " " + (scan.stderr || ""));
    const dirs = [];
    for (const listed of JSON.parse(scan.stdout)) {
        const rel = path.relative(root, listed.dir);
        if (listed.error !== undefined) unreadable(rel, listed.error);
        dirs.push(rel);
    }
    if (dirs.length === 0) unreadable("shell/plugins", "vgsh-scan listed no plugin, and the core always ships some");
    return dirs;
})();

// ---- README ----------------------------------------------------------------

const readmeLines = readText(README).split("\n");

// The lines of the `## <title>` section as [{ n, text }], n from 1, or
// null when the heading is absent.
function section(title) {
    const start = readmeLines.findIndex(line => line === "## " + title);
    if (start < 0) {
        finding("section", 1, "missing=## " + title);
        return null;
    }
    const lines = [];
    for (let i = start + 1; i < readmeLines.length && !readmeLines[i].startsWith("## "); i++)
        lines.push({ n: i + 1, text: readmeLines[i] });
    return { n: start + 1, lines };
}

// The fences of a section as [{ lang, n, lines: [{ n, text }] }].
function fences(sec) {
    const found = [];
    let open = null;
    for (const line of sec.lines) {
        const m = /^\x60\x60\x60(\S*)\s*$/.exec(line.text);
        if (open === null && m !== null) open = { lang: m[1], n: line.n, lines: [] };
        else if (open !== null && line.text.trim() === "```") {
            found.push(open);
            open = null;
        } else if (open !== null) open.lines.push(line);
    }
    if (open !== null) finding("section", open.n, "fence=unclosed");
    return found;
}

const regexEscape = text => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

function checkFloor(install) {
    const paragraph = [];
    for (const line of install.lines) {
        if (line.text.trim() === "") {
            if (paragraph.length > 0) break;
            continue;
        }
        paragraph.push(line);
    }
    const text = paragraph.map(line => line.text).join(" ");
    const at = paragraph.length > 0 ? paragraph[0].n : install.n;
    for (const { tool, need } of floors) {
        const phrase = need === "present" ? regexEscape(tool) : regexEscape(tool) + " " + regexEscape(need) + " or later";
        if (!new RegExp("(^|[^A-Za-z0-9.])" + phrase + "($|[^A-Za-z0-9])", "i").test(text))
            finding("floor", at, `tool=${tool} need=${need}`);
    }
}

// The vgsh arguments ARGS as a string when their first word is a command
// the usage header lists, else a finding.
function vgshArgs(args, n) {
    const first = args.split(/\s+/)[0];
    if (!vgshCommands.has(first)) {
        finding("command", n, `vgsh-command=${first} reason=not-in-usage`);
        return null;
    }
    return args;
}

// One command line as { channel, needs, vgsh }, or null after a finding.
function classify(command, n) {
    let m;
    if ((m = /^yay -S (\S+)$/.exec(command)) !== null) {
        const pkg = m[1];
        if (!fs.existsSync(path.join(root, "packaging", "arch", pkg, "PKGBUILD"))) {
            finding("command", n, `channel=aur package=${pkg} reason=no-recipe`);
            return null;
        }
        return { channel: "aur", needs: "aur:" + pkg, vgsh: null };
    }
    const curl = `curl -fsSL ${INSTALL_URL} | bash`;
    if (command === curl || command.startsWith(curl + " ")) {
        const rest = command.slice(curl.length).trim();
        if (rest === "") return { channel: "curl", needs: `release:v${version}`, vgsh: null };
        if (!rest.startsWith("-s -- ")) {
            finding("command", n, "channel=curl reason=unknown-form text=" + rest);
            return null;
        }
        const words = rest.slice("-s -- ".length).trim().split(/\s+/);
        let release = true, ok = true;
        for (let i = 0; i < words.length; i++) {
            const [option, inline] = words[i].split(/=(.*)/s, 2);
            if (!installOptions.has(option)) {
                finding("command", n, `channel=curl option=${option} reason=not-in-install.sh`);
                ok = false;
                continue;
            }
            if (option === "--version") {
                const value = inline !== undefined ? inline : words[++i];
                if (value !== "v" + version) {
                    finding("command", n, `channel=curl version=${value} want=v${version}`);
                    ok = false;
                }
            }
            if (option === "--git" || option === "--uninstall") release = false;
        }
        return ok ? { channel: "curl", needs: release ? `release:v${version}` : "none", vgsh: null } : null;
    }
    if ((m = /^nix run github:vanillagreencom\/vgs\/(\S+) -- (.+)$/.exec(command)) !== null) {
        if (m[1] !== "v" + version) {
            finding("command", n, `channel=nix tag=${m[1]} want=v${version}`);
            return null;
        }
        const vgsh = vgshArgs(m[2], n);
        return vgsh === null ? null : { channel: "nix", needs: `release:v${version}`, vgsh };
    }
    if (command === `git clone ${CLONE_URL}`) return { channel: "checkout", needs: "none", vgsh: null };
    if ((m = /^vgs\/bin\/vgsh (.+)$/.exec(command)) !== null) {
        const vgsh = vgshArgs(m[1], n);
        return vgsh === null ? null : { channel: "checkout", needs: "none", vgsh };
    }
    finding("command", n, "unknown text=" + command);
    return null;
}

function checkCommands(install) {
    const commands = [];
    let block = 0;
    for (const fence of fences(install).filter(f => f.lang === "bash")) {
        block++;
        for (const line of fence.lines) {
            const command = line.text.replace(/(^|\s)#.*$/, "").trim();
            if (command === "") continue;
            const judged = classify(command, line.n);
            if (judged !== null) commands.push({ block, line: line.n, ...judged, command });
        }
    }
    if (commands.length === 0 && !findings.some(f => f.startsWith("command "))) finding("command", install.n, "count=0");
    return commands;
}

function checkAutostart(install) {
    const lua = fences(install).filter(f => f.lang === "lua");
    if (lua.length !== 1) {
        finding("autostart", install.n, "lua-fences=" + lua.length + " want=1");
        return;
    }
    const lines = lua[0].lines.filter(line => line.text.trim() !== "");
    if (lines.length !== 1) {
        finding("autostart", lua[0].n, "lines=" + lines.length + " want=1");
        return;
    }
    const line = lines[0].text.trim();
    if (line !== runtimeAutostart) finding("autostart", lines[0].n, "differs=docs/architecture/runtime.md want=" + runtimeAutostart);
    if (line !== installAutostart) finding("autostart", lines[0].n, "differs=install.sh want=" + installAutostart);
}

function checkPlugins(shipped) {
    const rows = new Map(pluginDirs.map(dir => [dir, []]));
    for (const line of shipped.lines) {
        if (!line.text.startsWith("|") || /^\|[\s|:-]*$/.test(line.text)) continue;
        const cell = line.text.split("|")[1];
        const link = /\[[^\]]*\]\(([^)\s]+)\)/.exec(cell);
        if (link === null) {
            if (cell.trim() !== "Plugin") finding("plugin", line.n, "link=none");
            continue;
        }
        const target = link[1].replace(/\/$/, "");
        const m = /^(shell\/plugins\/[^/]+)(\/.*)?$/.exec(target);
        if (m === null || !rows.has(m[1])) {
            finding("plugin", line.n, `link=${link[1]} reason=not-a-plugin`);
            continue;
        }
        if (!fs.existsSync(path.join(root, target))) finding("plugin", line.n, `link=${link[1]} reason=missing-target`);
        rows.get(m[1]).push(line.n);
    }
    for (const [dir, lines] of rows) {
        if (lines.length === 0) finding("plugin", shipped.n, "missing=" + dir);
        if (lines.length > 1) finding("plugin", lines[1], `duplicate=${dir} first=${lines[0]}`);
    }
}

function checkLicence(licence) {
    for (const line of licence.lines) {
        const m = /The package licence is \x60([^\x60]+)\x60/.exec(line.text);
        if (m === null) continue;
        if (m[1] !== pkgbuildLicence) finding("licence", line.n, `have=${m[1]} want=${pkgbuildLicence}`);
        return;
    }
    finding("licence", licence.n, "sentence=missing want=The package licence is `" + pkgbuildLicence + "`");
}

const install = section("Install");
const shipped = section("Shipped plugins");
const licence = section("Licence");
let commands = [];
if (install !== null) {
    checkFloor(install);
    commands = checkCommands(install);
    checkAutostart(install);
}
if (shipped !== null) checkPlugins(shipped);
if (licence !== null) checkLicence(licence);

if (findings.length > 0) {
    process.stdout.write(findings.join("\n") + "\n");
    process.exit(1);
}
if (commandsMode) {
    for (const c of commands)
        process.stdout.write(JSON.stringify({ block: c.block, line: c.line, channel: c.channel, needs: c.needs, vgsh: c.vgsh, command: c.command }) + "\n");
} else {
    console.log(`check-readme: ok commands=${commands.length} plugins=${pluginDirs.length}`);
}
