#!/usr/bin/env node
// Check every distribution recipe in this repository offline against the
// requirements VGS declares. One checker serves every channel.
//
//   node scripts/check-packaging.js [--root DIR]
//
// DIR, this repository by default, holds the data judged: VERSION,
// bin/vgsh's preflight_floor table, config/requirements.json, the plugins
// under shell/plugins, packaging/arch, packaging/fedora, and the git
// repository the release-tag lookup reads. The judge, its loader and
// bin/vgsh-scan always come from this script's own repository, so a data
// root needs none of their code.
//
// One reader, readRequirements, builds the normalized requirement list:
//   - config/requirements.json, the core's commands, and each shipped
//     plugin's manifest `requirements`, listed by bin/vgsh-scan and judged
//     by shell/Core/PluginLogic.js;
//   - bin/vgsh's preflight_floor table, the versions `vgsh run` refuses to
//     start below. A row attaches to the first requirement whose command is
//     the row's probe command, else it adds one. A row makes its
//     requirement required, and names its package: the declared package for
//     a manager, else the row's tool name. `present` sets no version.
// Each entry is { scope, command, packages, optional, floor, tool }: scope
// `core` or the plugin id, packages keyed by manager id, floor a dotted
// version or null, tool the preflight row's tool or null.
//
// CHANNELS holds one entry per channel whose recipes live here, keyed by
// the package manager id. An entry names its recipes and reads each one
// into hard and soft dependencies; its fields set how the shared rules
// judge it; its `rules` hold the channel's own recipe rules and its
// `freshness` any check against generated metadata. Every channel gets the
// shared rules, per recipe, in this order:
//   requirement  each requirement's package (the first of the entry's
//                `managers` it names) is a hard dependency when it has a
//                floor or is required and in `hardScopes`; any other one is
//                a soft dependency when the entry is `exact`, else hard or
//                soft
//   floor        a floored hard dependency is constrained `>=` the floor:
//                exactly the floor when the entry is `floorExact`, else at
//                or above it; under `floorExact` a hard dependency with no
//                floor carries no constraint. With `epochs`, the
//                constraint's epoch is the package's epoch there, else 0
//   extra        when the entry is `exact`, no hard or soft dependency the
//                requirements do not ask for
//   agree        every recipe of the channel declares the same hard and the
//                same soft dependencies
// pacman (packaging/arch/{vgs,vgs-git}/.SRCINFO): depends and optdepends;
// optdepends may name more than the requirements. vgs: pkgver is VERSION's
// line; arch is any; conflicts holds vgs-shell and vgs-shell-git; no
// replaces; source is the release tarball URL; one sha256sums entry, SKIP
// only while the tag v<pkgver> does not exist, otherwise 64 lower-case hex
// digits. vgs-git: arch is any; conflicts holds vgs, vgs-shell and
// vgs-shell-git; provides holds vgs=<pkgver>; makedepends holds git; no
// replaces; source is the git+https URL. Freshness, last: each .SRCINFO is
// exactly `makepkg --printsrcinfo` of the PKGBUILD beside it.
// dnf (packaging/fedora/{vgs,vgs-git}.spec): the Requires and Recommends
// lines between `# begin runtime dependencies` and `# end runtime
// dependencies`, exactly the requirements' set. The block is the same in
// both specs; both are noarch, named for their package, share License, URL,
// BuildRequires and the %build, %install, %check and %files sections,
// install through packaging/install-system.sh and check the tree with
// scripts/check-install-tree.sh. vgs.spec's Version is VERSION's line and
// its newest %changelog entry is that version at its Release. vgs-git.spec
// provides vgs at its version, conflicts with vgs and ends with an empty
// %changelog, which packaging/fedora/srpm.sh fills.
//
// Exit 0 prints `check-packaging: ok channels=<ids> requirements=<n>`, n
// the entries of the normalized list. Exit 1 prints one keyed first line,
// `check-packaging: refused: <key>=<value> ...`, detail after it. Exit 77
// prints `check-packaging: status=not-measured reason=<tool>-missing
// channel=<id>` when every other rule passed and a freshness tool is not on
// PATH; that is not a pass. Exit 2: an argument. The judge's loader refuses
// an unloadable library with its own keyed line, `qml-library: refused:
// ...`, and exit 2. An argument other than `--root DIR` is refused as
// `argument=<arg>`, exit 2.
"use strict";
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { parseFloors, DOTTED } = require("./preflight-floor.js");

// The repository this script runs from: the judge, its loader and the scan.
const codeRoot = path.resolve(__dirname, "..");
// The data judged: codeRoot, or --root DIR.
const root = (() => {
    const args = process.argv.slice(2);
    if (args.length === 0) return codeRoot;
    if (args.length === 2 && args[0] === "--root" && args[1] !== "") return path.resolve(args[1]);
    process.stdout.write("check-packaging: refused: argument=" + args.join(" ") + "\n");
    return process.exit(2);
})();
const REPO_URL = "https://github.com/vanillagreencom/vgs";

const scratchDirs = [];
process.on("exit", () => { for (const dir of scratchDirs) fs.rmSync(dir, { recursive: true, force: true }); });

function refuse(key, ...detail) {
    process.stdout.write("check-packaging: refused: " + key + "\n" + detail.filter(line => line !== "").map(line => line + "\n").join(""));
    process.exit(1);
}

function readText(rel, key) {
    try {
        return fs.readFileSync(path.join(root, rel), "utf8");
    } catch (e) {
        return refuse(key + " path=" + rel, e.code || String(e));
    }
}

// True when HAVE >= NEED, both dotted decimal integers compared component
// by component, a missing component 0: bin/vgsh's version_at_least.
function atLeast(have, need) {
    const a = have.split(".").map(Number), b = need.split(".").map(Number);
    for (let i = 0; i < Math.max(a.length, b.length); i++) {
        const x = a[i] || 0, y = b[i] || 0;
        if (x !== y) return x > y;
    }
    return true;
}

// bin/vgsh's preflight_floor rows as [{ tool, need, probe }], read by
// scripts/preflight-floor.js.
function readFloors() {
    const read = parseFloors(readText("bin/vgsh", "floors=unreadable"));
    if (!read.ok) refuse(read.key + " path=bin/vgsh", read.detail);
    return read.rows;
}

function readRequirements() {
    const ctx = require(path.join(codeRoot, "bin", "lib", "qml-library.js")).load(path.join(codeRoot, "shell", "Core", "PluginLogic.js"));
    const coreRel = "config/requirements.json";
    let core;
    try {
        core = JSON.parse(readText(coreRel, "requirements=unreadable"));
    } catch (e) {
        refuse("requirements=unreadable path=" + coreRel, e.message);
    }
    const coreError = ctx.requirementsError(core);
    if (coreError !== "") refuse("requirements=refused path=" + coreRel, coreError);
    if (core.length === 0) refuse("requirements=empty scope=core", "the core list is never empty, so the reader is broken");
    const entry = (scope, r) => ({ scope, command: r.command, packages: r.packages, optional: r.optional, floor: null, tool: null });
    const list = ctx.normalRequirements(core).map(r => entry("core", r));

    const base = path.join(root, "shell", "plugins");
    const scan = childProcess.spawnSync(path.join(codeRoot, "bin", "vgsh-scan"), ["--require-base", base], { encoding: "utf8", env: { PATH: process.env.PATH, LC_ALL: "C" } });
    if (scan.error || scan.status !== 0) refuse("requirements=unreadable scan=" + (scan.error ? scan.error.code : scan.status), scan.stderr || "");
    for (const listed of JSON.parse(scan.stdout)) {
        const rel = path.relative(root, listed.dir);
        if (listed.error !== undefined) refuse("requirements=unreadable path=" + rel, listed.error);
        let raw;
        try {
            raw = JSON.parse(listed.text);
        } catch (e) {
            refuse("requirements=unreadable path=" + rel, e.message);
        }
        const judged = ctx.validateManifest(raw, listed.dir);
        if (!judged.ok) refuse("requirements=refused path=" + rel, judged.error);
        for (const r of judged.manifest.requirements) list.push(entry(judged.manifest.id, r));
    }

    for (const { tool, need, probe } of readFloors()) {
        let floored = list.find(e => e.command === probe);
        if (floored === undefined) {
            floored = { scope: "core", command: probe, packages: {}, optional: false, floor: null, tool: null };
            list.push(floored);
        }
        floored.optional = false;
        floored.floor = need === "present" ? null : need;
        floored.tool = tool;
    }
    return list;
}

// A requirement's package on a channel: the first of MANAGERS it names,
// else a preflight row's tool name, else undefined.
function packageOf(requirement, managers) {
    for (const manager of managers)
        if (requirement.packages[manager] !== undefined) return requirement.packages[manager];
    return requirement.tool !== null ? requirement.tool : undefined;
}

function one(values) {
    return (values || []).join(",");
}

// Whether the tag exists in this repository.
function tagExists(tag) {
    const probe = childProcess.spawnSync("git", ["-C", root, "rev-parse", "-q", "--verify", "refs/tags/" + tag], { encoding: "utf8" });
    if (probe.status === 0) return true;
    if (probe.status === 1) return false;
    return refuse("tag=unreadable status=" + (probe.error ? probe.error.code : probe.status) + " root=" + root, probe.stderr || "");
}

// ---- pacman ----------------------------------------------------------------

// A depends, optdepends or makedepends entry: `name[op version][: reason]`.
function pacmanEntry(text) {
    const m = /^([^<>=:\s]+)(?:(>=|<=|=|<|>)([^:\s]+))?(?::.*)?$/.exec(text);
    if (m === null) refuse("entry=unreadable text=" + text);
    return { name: m[1], op: m[2] || "", version: m[3] || "", epoch: "", text };
}

// .SRCINFO as { key: [values] } in file order.
function readSrcinfo(recipe) {
    const rel = recipe.dir + "/.SRCINFO";
    const info = {};
    for (const line of readText(rel, "srcinfo=missing recipe=" + recipe.name).split("\n")) {
        const m = /^\s*([a-z0-9_]+) = (.*)$/.exec(line);
        if (m !== null) (info[m[1]] = info[m[1]] || []).push(m[2]);
    }
    const base = one(info.pkgbase);
    if (base !== recipe.name) refuse("pkgbase=" + (base || "missing") + " recipe=" + recipe.name);
    return { hard: (info.depends || []).map(pacmanEntry), soft: (info.optdepends || []).map(pacmanEntry), info };
}

function pacmanRules(recipes, reads, version) {
    recipes.forEach((recipe, i) => {
        const info = reads[i].info;
        const has = (key, value) => (info[key] || []).includes(value);
        if (one(info.arch) !== "any") refuse("arch=" + one(info.arch) + " recipe=" + recipe.name);
        if ((info.replaces || []).length > 0) refuse("replaces=" + one(info.replaces) + " recipe=" + recipe.name);
        const conflicts = recipe.name === "vgs-git" ? ["vgs", "vgs-shell", "vgs-shell-git"] : ["vgs-shell", "vgs-shell-git"];
        for (const conflict of conflicts)
            if (!has("conflicts", conflict)) refuse("conflicts=missing package=" + conflict + " recipe=" + recipe.name);
        const pkgver = one(info.pkgver);
        if (recipe.name === "vgs") {
            if (pkgver !== version) refuse("pkgver=" + pkgver + " version=" + version + " recipe=vgs");
            const want = `vgs-${pkgver}.tar.gz::${REPO_URL}/releases/download/v${pkgver}/vgs-${pkgver}.tar.gz`;
            if (one(info.source) !== want) refuse("source=" + one(info.source) + " recipe=vgs", "want " + want);
            const sums = info.sha256sums || [];
            if (sums.length !== 1) refuse("sha256sums=count count=" + sums.length + " recipe=vgs");
            if (sums[0] === "SKIP") {
                if (tagExists("v" + pkgver)) refuse("sha256sums=SKIP tag=v" + pkgver + " recipe=vgs", "the release tag exists: pin the release tarball's sha256");
            } else if (!/^[0-9a-f]{64}$/.test(sums[0])) {
                refuse("sha256sums=" + sums[0] + " recipe=vgs", "want SKIP before the tag v" + pkgver + " exists, else 64 lower-case hex digits");
            }
        } else {
            const want = `vgs::git+${REPO_URL}.git`;
            if (one(info.source) !== want) refuse("source=" + one(info.source) + " recipe=vgs-git", "want " + want);
            if (!has("provides", "vgs=" + pkgver)) refuse("provides=missing want=vgs=" + pkgver + " recipe=vgs-git");
            if (!(info.makedepends || []).some(text => pacmanEntry(text).name === "git")) refuse("makedepends=missing package=git recipe=vgs-git");
        }
    });
}

// makepkg --printsrcinfo of a scratch copy of the PKGBUILD equals the
// committed .SRCINFO; null when makepkg is not on PATH.
function pacmanFresh(recipe) {
    const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "check-packaging-"));
    scratchDirs.push(scratch);
    fs.copyFileSync(path.join(root, recipe.dir, "PKGBUILD"), path.join(scratch, "PKGBUILD"));
    const run = childProcess.spawnSync("makepkg", ["--printsrcinfo"], { cwd: scratch, encoding: "utf8" });
    if (run.error && run.error.code === "ENOENT") return null;
    if (run.error || run.status !== 0) refuse("srcinfo=unreadable recipe=" + recipe.name + " status=" + (run.error ? run.error.code : run.status), run.stderr || "");
    if (run.stdout !== readText(recipe.dir + "/.SRCINFO", "srcinfo=missing recipe=" + recipe.name))
        refuse("srcinfo=stale recipe=" + recipe.name, `run: (cd ${recipe.dir} && makepkg --printsrcinfo > .SRCINFO)`);
    return true;
}

// ---- dnf -------------------------------------------------------------------

const DNF_BEGIN = "# begin runtime dependencies";
const DNF_END = "# end runtime dependencies";
const DNF_LINE = /^(Requires|Recommends|Conflicts):\s+(\S+)(?:\s+>=\s+(?:(\d+):)?(\S+))?\s*$/;
const DNF_SECTION = /^%(description|prep|build|install|check|files|changelog)\b/;
const DNF_INSTALL = "DESTDIR=%{buildroot} PREFIX=%{_prefix} packaging/install-system.sh";
const DNF_CHECK = "scripts/check-install-tree.sh %{buildroot} %{_prefix}";

// A spec's preamble tags, sections and runtime dependency block.
function readSpec(recipe) {
    const lines = readText(recipe.file, "spec=missing").split("\n");
    const tags = {}, sections = {};
    let section = null;
    for (const line of lines) {
        const found = DNF_SECTION.exec(line);
        if (found !== null) {
            section = "%" + found[1];
            sections[section] = [];
        } else if (section !== null) {
            sections[section].push(line);
        } else {
            const tag = /^([A-Za-z0-9]+):\s*(.*?)\s*$/.exec(line);
            if (tag !== null) (tags[tag[1]] = tags[tag[1]] || []).push(tag[2]);
        }
    }
    for (const body of Object.values(sections)) while (body.length > 0 && body[body.length - 1].trim() === "") body.pop();
    const starts = lines.flatMap((line, i) => line.trim() === DNF_BEGIN ? [i] : []);
    const ends = lines.flatMap((line, i) => line.trim() === DNF_END ? [i] : []);
    if (starts.length !== 1 || ends.length !== 1 || ends[0] < starts[0]) refuse("block=missing spec=" + recipe.spec);
    const block = lines.slice(starts[0] + 1, ends[0]).map(line => line.trim()).filter(line => line !== "" && !line.startsWith("#"));
    const hard = [], soft = [];
    for (const line of block) {
        const m = DNF_LINE.exec(line);
        if (m === null) refuse("line=unreadable spec=" + recipe.spec + " text=" + line);
        const dep = { name: m[2], op: m[4] !== undefined ? ">=" : "", version: m[4] || "", epoch: m[3] || "0", text: line };
        if (m[1] === "Requires") hard.push(dep);
        else if (m[1] === "Recommends") soft.push(dep);
    }
    return { hard, soft, tags, sections, block };
}

function dnfRules(recipes, reads, version) {
    const [rel, git] = reads;
    const tagOne = (read, tag, spec) => {
        const values = read.tags[tag] || [];
        if (values.length !== 1) refuse("tag=missing name=" + tag + " spec=" + spec);
        return values[0];
    };
    if (rel.block.join("\n") !== git.block.join("\n")) refuse("block=differs specs=vgs.spec,vgs-git.spec");
    recipes.forEach((recipe, i) => {
        const name = tagOne(reads[i], "Name", recipe.spec);
        if (name !== recipe.name) refuse(`name=mismatch spec=${recipe.spec} have=${name} want=${recipe.name}`);
        const arch = tagOne(reads[i], "BuildArch", recipe.spec);
        if (arch !== "noarch") refuse(`buildarch=${arch} spec=${recipe.spec} want=noarch`);
    });
    for (const tag of ["License", "URL", "BuildRequires"]) {
        const a = (rel.tags[tag] || []).slice().sort(), b = (git.tags[tag] || []).slice().sort();
        if (a.length === 0 || a.join("\n") !== b.join("\n")) refuse("tag=differs name=" + tag + " specs=vgs.spec,vgs-git.spec");
    }
    for (const section of ["%build", "%install", "%check", "%files"]) {
        if (rel.sections[section] === undefined || (rel.sections[section] || []).join("\n") !== (git.sections[section] || []).join("\n"))
            refuse("section=differs name=" + section + " specs=vgs.spec,vgs-git.spec");
    }
    if (!(rel.sections["%install"] || []).some(line => line.trim() === DNF_INSTALL)) refuse("install=missing want=" + DNF_INSTALL);
    if (!(rel.sections["%check"] || []).some(line => line.trim() === DNF_CHECK)) refuse("check=missing want=" + DNF_CHECK);
    const relVersion = tagOne(rel, "Version", "vgs.spec");
    if (relVersion !== version) refuse(`version=mismatch spec=vgs.spec have=${relVersion} want=${version}`);
    const release = tagOne(rel, "Release", "vgs.spec").replace("%{?dist}", "");
    const entries = (rel.sections["%changelog"] || []).filter(line => line.startsWith("* "));
    const wantEntry = `- ${relVersion}-${release}`;
    if (entries.length === 0 || !entries[0].endsWith(wantEntry))
        refuse(`changelog=mismatch spec=vgs.spec want=...${wantEntry} have=${entries.length > 0 ? entries[0] : "none"}`);
    if (!(git.tags.Provides || []).includes("vgs = %{version}")) refuse("provides=missing spec=vgs-git.spec want=vgs = %{version}");
    if (!(git.tags.Conflicts || []).includes("vgs")) refuse("conflicts=missing spec=vgs-git.spec want=vgs");
    if (git.sections["%changelog"] === undefined) refuse("changelog=missing spec=vgs-git.spec");
    if (git.sections["%changelog"].some(line => line.trim() !== "")) refuse("changelog=entries spec=vgs-git.spec", "want empty: srpm.sh writes the entry");
}

// ---- channels --------------------------------------------------------------

// One entry per package manager id with recipes here. A new channel is one
// entry: its recipes, a reader returning { hard, soft, ... } with each
// dependency as { name, op, version, epoch, text }, the fields the shared
// rules read, its own rules over all its recipes, and its freshness check
// or null. Its controls go in scripts/test-check-packaging.js ROWS.
const CHANNELS = {
    pacman: {
        recipes: [{ name: "vgs", dir: "packaging/arch/vgs" }, { name: "vgs-git", dir: "packaging/arch/vgs-git" }],
        managers: ["pacman", "aur"],
        hardField: "depends",
        softField: "optdepends",
        hardScopes: "core",
        exact: false,
        floorExact: false,
        epochs: null,
        read: readSrcinfo,
        rules: pacmanRules,
        freshness: { tool: "makepkg", check: pacmanFresh },
    },
    dnf: {
        recipes: [{ name: "vgs", spec: "vgs.spec", file: "packaging/fedora/vgs.spec" }, { name: "vgs-git", spec: "vgs-git.spec", file: "packaging/fedora/vgs-git.spec" }],
        managers: ["dnf"],
        hardField: "Requires",
        softField: "Recommends",
        hardScopes: "all",
        exact: true,
        floorExact: true,
        // The epoch Fedora's packages carry, where it is not 0. A floor
        // written without it reads as epoch 0, which every epoch-1 build
        // passes whatever its version. nodejs22 is 1:22.23.1 on Fedora 44
        // (read 2026-09-28); scripts/fedora-container.sh checks each floor's
        // epoch against the installed package's.
        epochs: { nodejs: "1" },
        read: readSpec,
        rules: dnfRules,
        freshness: null,
    },
};

function sharedRules(id, channel, recipe, read, requirements) {
    const where = r => ` channel=${id} recipe=${recipe.name} scope=${r.scope}`;
    const hardWant = new Map(), softWant = new Map();
    for (const r of requirements) {
        const pkg = packageOf(r, channel.managers);
        if (pkg === undefined) continue;
        if (r.tool !== null || (!r.optional && (channel.hardScopes === "all" || r.scope === "core"))) {
            if (!hardWant.has(pkg)) hardWant.set(pkg, r);
        } else if (!softWant.has(pkg)) {
            softWant.set(pkg, r);
        }
    }
    for (const pkg of hardWant.keys()) softWant.delete(pkg);
    const hard = new Map(read.hard.map(dep => [dep.name, dep]));
    const soft = new Map(read.soft.map(dep => [dep.name, dep]));
    for (const [pkg, r] of hardWant) {
        const dep = hard.get(pkg);
        if (dep === undefined) refuse(`requirement=${r.command} package=${pkg} want=${channel.hardField}` + where(r));
        if (channel.floorExact) {
            const have = dep.version || "none", want = r.floor || "none";
            if (have !== want) refuse(`floor=mismatch package=${pkg} have=${have} want=${want}` + where(r));
        } else if (r.floor !== null) {
            if (dep.op !== ">=" || !DOTTED.test(dep.version)) refuse(`floor=missing package=${pkg} want=>=${r.floor}` + where(r));
            if (!atLeast(dep.version, r.floor)) refuse(`floor=below package=${pkg} have=>=${dep.version} want=>=${r.floor}` + where(r));
        }
        if (channel.epochs !== null && r.floor !== null) {
            const want = channel.epochs[pkg] || "0";
            if (dep.epoch !== want) refuse(`epoch=mismatch package=${pkg} have=${dep.epoch} want=${want}` + where(r));
        }
    }
    for (const [pkg, r] of softWant) {
        if (channel.exact) {
            if (!soft.has(pkg)) refuse(`requirement=${r.command} package=${pkg} want=${channel.softField}` + where(r));
        } else if (!hard.has(pkg) && !soft.has(pkg)) {
            refuse(`requirement=${r.command} package=${pkg} want=${channel.hardField}-or-${channel.softField}` + where(r));
        }
    }
    if (channel.exact) {
        for (const [field, have, want] of [[channel.hardField, hard, hardWant], [channel.softField, soft, softWant]])
            for (const pkg of have.keys())
                if (!want.has(pkg)) refuse(`extra=${pkg} field=${field} channel=${id} recipe=${recipe.name}`);
    }
}

const requirements = readRequirements();
const version = readText("VERSION", "version=missing").replace(/\n$/, "");
const judged = [];
for (const [id, channel] of Object.entries(CHANNELS)) {
    const reads = channel.recipes.map(recipe => channel.read(recipe));
    channel.recipes.forEach((recipe, i) => sharedRules(id, channel, recipe, reads[i], requirements));
    for (const [field, key] of [[channel.hardField, "hard"], [channel.softField, "soft"]]) {
        const sets = reads.map(read => read[key].map(dep => dep.text).sort().join("\n"));
        if (sets.some(set => set !== sets[0]))
            refuse(`${field}=differ channel=${id} recipes=${channel.recipes.map(r => r.name).join(",")}`);
    }
    channel.rules(channel.recipes, reads, version);
    judged.push(id);
}
// Freshness last, so a missing tool still leaves every other rule judged.
const notMeasured = [];
for (const id of judged) {
    const freshness = CHANNELS[id].freshness;
    if (freshness === null) continue;
    for (const recipe of CHANNELS[id].recipes) {
        if (freshness.check(recipe) === null) {
            notMeasured.push(`check-packaging: status=not-measured reason=${freshness.tool}-missing channel=${id}`);
            break;
        }
    }
}
if (notMeasured.length > 0) {
    process.stdout.write(notMeasured.join("\n") + "\nevery other rule passed; install the tool to compare each recipe with its generated metadata\n");
    process.exit(77);
}
console.log(`check-packaging: ok channels=${judged.join(",")} requirements=${requirements.length}`);
