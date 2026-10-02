#!/usr/bin/env node
// Controls for scripts/check-packaging.js, one table for every channel. Every
// row runs this repository's check with `--root` on a scratch data tree
// under its tmp/: the Arch recipes and the Fedora specs, VERSION, bin/vgsh
// (its preflight floors), the core requirements and each shipped plugin's
// manifest, committed to the tree's own git repository so the release-tag
// rule reads that repository alone. The tree holds no code: the check loads
// the judge and bin/vgsh-scan from its own repository, so a new import of
// the judge needs no change here. The pristine tree passes.
// Each other row plants one defect that reaches one rule in a fresh copy and
// asserts the exit status and the exact keyed first line. Every edit asserts
// it matched once and changed its file. A release step legitimately changes
// the recipes and bin/vgsh (a VERSION bump, a pinned sha256, a pkgver
// makepkg rewrote, a raised floor), so no row reads its expectation from
// this repository's current values: each reads them from the copy it
// edits, and a checksum row sets its checksum state first. A channel added
// to CHANNELS adds its rows to ROWS here.
"use strict";
const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const repo = path.resolve(__dirname, "..");
const hasMakepkg = childProcess.spawnSync("makepkg", ["--version"], { encoding: "utf8" });
if (hasMakepkg.error) {
    // The freshness rule and every row that reaches it need makepkg.
    console.log("test-check-packaging: status=not-measured reason=makepkg-missing");
    process.exit(77);
}
const tmp = path.join(repo, "tmp", "test-check-packaging." + process.pid);
fs.rmSync(tmp, { recursive: true, force: true });
fs.mkdirSync(path.join(tmp, "home"), { recursive: true });
process.on("exit", () => fs.rmSync(tmp, { recursive: true, force: true }));

// Every check and git call runs with this environment and nothing else.
const basePath = path.dirname(process.execPath) + ":" + process.env.PATH;
const ENV = {
    HOME: path.join(tmp, "home"), LC_ALL: "C", TMPDIR: tmp, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.invalid", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.invalid",
};
function git(...args) {
    const run = childProcess.spawnSync("git", args, { encoding: "utf8", env: { ...ENV, PATH: basePath } });
    if (run.status !== 0) throw new Error("git " + args.join(" ") + ": " + run.stderr);
    return run.stdout;
}

const pristine = path.join(tmp, "pristine");
const files = ["packaging/runtime-libraries.json", "VERSION", "config/requirements.json", "bin/vgsh"];
for (const plugin of fs.readdirSync(path.join(repo, "shell", "plugins"))) {
    if (fs.existsSync(path.join(repo, "shell", "plugins", plugin, "manifest.json"))) files.push(`shell/plugins/${plugin}/manifest.json`);
}
for (const rel of files) {
    fs.mkdirSync(path.dirname(path.join(pristine, rel)), { recursive: true });
    fs.copyFileSync(path.join(repo, rel), path.join(pristine, rel));
    fs.chmodSync(path.join(pristine, rel), fs.statSync(path.join(repo, rel)).mode);
}
fs.cpSync(path.join(repo, "packaging", "arch"), path.join(pristine, "packaging", "arch"), { recursive: true });
for (const spec of ["vgs.spec", "vgs-git.spec"]) {
    fs.mkdirSync(path.join(pristine, "packaging", "fedora"), { recursive: true });
    fs.copyFileSync(path.join(repo, "packaging", "fedora", spec), path.join(pristine, "packaging", "fedora", spec));
}
git("init", "-q", pristine);
git("-C", pristine, "add", "-A");
git("-C", pristine, "commit", "-q", "-m", "pristine");

const sum = crypto.createHash("sha256").update("planted").digest("hex");

// The first value of KEY in a tree's .SRCINFO.
function srcinfo(tree, rel, key) {
    const m = new RegExp("^\\t" + key + " = (.*)$", "m").exec(fs.readFileSync(path.join(tree, rel), "utf8"));
    if (m === null) throw new Error(`srcinfo: refused: key=${key} path=${rel}`);
    return m[1];
}
// The version of a tree's bin/vgsh floor for TOOL.
function floorOf(tree, tool) {
    const m = new RegExp("^" + tool + " +([0-9.]+) ", "m").exec(fs.readFileSync(path.join(tree, "bin/vgsh"), "utf8"));
    if (m === null) throw new Error("floor: refused: tool=" + tool);
    return m[1];
}
// The >= version of a hard dependency on NAME in a tree's vgs .SRCINFO.
function constraintOf(tree, name) {
    const m = new RegExp("^\\tdepends = " + name + ">=([0-9.]+)$", "m").exec(fs.readFileSync(path.join(tree, "packaging/arch/vgs/.SRCINFO"), "utf8"));
    if (m === null) throw new Error("constraint: refused: package=" + name);
    return m[1];
}

// The expected count, read here from the declarations and not from the
// check: every core and shipped-plugin requirement, and each preflight row
// whose probe command no requirement declares.
function countRequirements(tree) {
    const lists = [JSON.parse(fs.readFileSync(path.join(tree, "config/requirements.json"), "utf8"))];
    for (const plugin of fs.readdirSync(path.join(tree, "shell/plugins")))
        lists.push(JSON.parse(fs.readFileSync(path.join(tree, "shell/plugins", plugin, "manifest.json"), "utf8")).requirements || []);
    const all = lists.flat();
    const table = fs.readFileSync(path.join(tree, "bin/vgsh"), "utf8").split("preflight_floor='\n")[1].split("\n'\n")[0];
    const probes = table.split("\n").filter(Boolean).map(line => line.trim().split(/\s+/)[3]);
    return all.length + probes.filter(probe => !all.some(entry => entry.command === probe)).length
        + JSON.parse(fs.readFileSync(path.join(tree, "packaging/runtime-libraries.json"), "utf8")).length;
}

function fresh(name) {
    const dir = path.join(tmp, name);
    fs.cpSync(pristine, dir, { recursive: true });
    return dir;
}

// Replace the one match of the multi-line PATTERN in TREE/REL.
function edit(tree, rel, pattern, replacement) {
    const file = path.join(tree, rel);
    if (fs.lstatSync(file).isSymbolicLink()) throw new Error("edit: refused: symlink=" + file);
    const text = fs.readFileSync(file, "utf8");
    const regex = new RegExp(pattern, "gm");
    const matches = (text.match(regex) || []).length;
    if (matches !== 1) throw new Error(`edit: refused: matches=${matches} path=${rel} pattern=${pattern}`);
    const changed = text.replace(regex, replacement);
    if (changed === text) throw new Error("edit: refused: unchanged path=" + rel);
    fs.writeFileSync(file, changed);
}
function write(tree, rel, text) { fs.writeFileSync(path.join(tree, rel), text); }

// Set the vgs recipe's one checksum in both the PKGBUILD and .SRCINFO of a
// copy, whatever it held: SKIP or a pin. Each file must hold exactly one
// checksum line, and must hold VALUE after the edit.
function setChecksum(tree, value) {
    for (const [rel, pattern, line] of [
        ["packaging/arch/vgs/PKGBUILD", "^sha256sums=\\('[^']*'\\)$", `sha256sums=('${value}')`],
        ["packaging/arch/vgs/.SRCINFO", "^\\tsha256sums = .*$", "\tsha256sums = " + value],
    ]) {
        const file = path.join(tree, rel);
        const text = fs.readFileSync(file, "utf8");
        const regex = new RegExp(pattern, "gm");
        const matches = (text.match(regex) || []).length;
        if (matches !== 1) throw new Error(`checksum: refused: matches=${matches} path=${rel}`);
        const changed = text.replace(regex, line);
        if (!changed.split("\n").includes(line)) throw new Error("checksum: refused: unset path=" + rel);
        fs.writeFileSync(file, changed);
    }
}

// Append a requirement to a copied plugin's manifest; PACKAGES keyed by
// manager id.
function addRequirement(tree, plugin, command, packages, optional) {
    const file = path.join(tree, "shell/plugins", plugin, "manifest.json");
    const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
    const requirements = manifest.requirements || [];
    if (requirements.some(entry => entry.command === command)) throw new Error("plugin requirement: refused: declared=" + command);
    manifest.requirements = requirements.concat([{ command, packages, optional, purpose: "A planted requirement" }]);
    fs.writeFileSync(file, JSON.stringify(manifest));
}

// Replace OLD, which must occur exactly once, in each of RELS.
function replaceIn(tree, rels, old, replacement) {
    for (const rel of rels) {
        const file = path.join(tree, rel);
        const text = fs.readFileSync(file, "utf8");
        const count = text.split(old).length - 1;
        if (count !== 1) throw new Error(`replace: refused: matches=${count} path=${rel} text=${JSON.stringify(old)}`);
        fs.writeFileSync(file, text.replace(old, () => replacement));
    }
}

// A spec's value of TAG, or the first %changelog entry line for "*".
function specValue(tree, rel, tag) {
    const text = fs.readFileSync(path.join(tree, rel), "utf8");
    const m = tag === "*" ? /^%changelog\n(\* .*)$/m.exec(text) : new RegExp("^" + tag + ":\\s*(.*?)\\s*$", "m").exec(text);
    if (m === null) throw new Error(`spec: refused: tag=${tag} path=${rel}`);
    return m[1];
}
// The version a spec's Requires line on NAME carries, without its epoch.
function specFloor(tree, rel, name) {
    const m = new RegExp("^Requires:\\s+" + name + " >= (?:\\d+:)?(\\S+)$", "m").exec(fs.readFileSync(path.join(tree, rel), "utf8"));
    if (m === null) throw new Error(`spec: refused: floor=${name} path=${rel}`);
    return m[1];
}

function plantPluginRequirement(tree, command, pkg) {
    const file = path.join(tree, "shell/plugins/vgs.launcher/manifest.json");
    const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
    const requirements = manifest.requirements || [];
    if (requirements.some(entry => entry.command === command)) throw new Error("plugin requirement: refused: declared=" + command);
    manifest.requirements = requirements.concat([{ command, packages: { pacman: pkg }, optional: true, purpose: "A planted requirement" }]);
    fs.writeFileSync(file, JSON.stringify(manifest));
}

// A PATH holding what the check runs except makepkg: git, and python3 for
// bin/vgsh-scan's interpreter line.
const farm = path.join(tmp, "path-farm");
fs.mkdirSync(farm);
for (const command of ["git", "python3"]) {
    const found = childProcess.spawnSync("sh", ["-c", 'command -v "$1"', "sh", command], { encoding: "utf8" }).stdout.trim();
    if (found === "") throw new Error("path farm: " + command + " is not on PATH");
    fs.symlinkSync(found, path.join(farm, command));
}

const SRC = "packaging/arch/vgs/.SRCINFO";
const GIT_SRC = "packaging/arch/vgs-git/.SRCINFO";
const ok = n => `check-packaging: ok channels=pacman,dnf requirements=${n}`;
const REL = "packaging/fedora/vgs.spec";
const GIT = "packaging/fedora/vgs-git.spec";
const SPECS = [REL, GIT];
const dnf = (recipe = "vgs", scope = "core") => `channel=dnf recipe=${recipe} scope=${scope}`;
const firstPlugin = tree => fs.readdirSync(path.join(tree, "shell/plugins")).sort()[0];
const refused = key => "check-packaging: refused: " + key;
const where = (recipe = "vgs") => `channel=pacman recipe=${recipe} scope=core`;

// name | setup(tree) | exit | first line (a function of the tree) | PATH |
// arguments
const ROWS = [
    ["the committed recipes pass", () => {}, 0, tree => ok(countRequirements(tree))],
    ["a missing required runtime library is refused", t => edit(t, SRC, "^\\tdepends = libxkbcommon\\n", ""),
        1, () => refused("requirement=library:xkbcommon package=libxkbcommon want=depends " + where())],
    ["runtime library data rejects a duplicate identity", t => {
        const file = path.join(t, "packaging/runtime-libraries.json");
        const data = JSON.parse(fs.readFileSync(file, "utf8")); data.push(data[0]);
        fs.writeFileSync(file, JSON.stringify(data));
    }, 1, () => refused("libraries=shape")],
    ["a .SRCINFO older than its PKGBUILD is refused", t => edit(t, "packaging/arch/vgs/PKGBUILD", "^pkgdesc=.*$", "pkgdesc='Changed without regenerating .SRCINFO'"),
        1, () => refused("srcinfo=stale recipe=vgs")],
    ["a required core requirement in optdepends is refused", t => {
        edit(t, SRC, "^\\tdepends = nodejs(>=.*)?\\n", "");
        edit(t, SRC, "^(pkgbase = vgs\\n)", "$1\toptdepends = nodejs: moved\n");
    }, 1, () => refused("requirement=node package=nodejs want=depends " + where())],
    ["a missing optional core requirement is refused", t => edit(t, SRC, "^\\toptdepends = fzf: .*\\n", ""),
        1, () => refused("requirement=fzf package=fzf want=depends-or-optdepends " + where())],
    ["a shipped plugin's listed requirement passes and counts", t => plantPluginRequirement(t, "grim", "grim"), 0, tree => ok(countRequirements(tree))],
    ["a shipped plugin's unlisted requirement is refused", t => plantPluginRequirement(t, "vgs-planted", "vgs-planted-package"),
        1, () => refused("requirement=vgs-planted package=vgs-planted-package want=depends-or-optdepends channel=pacman recipe=vgs scope=vgs.launcher")],
    // Floors from bin/vgsh's preflight table.
    ["a floored depends without its constraint is refused", t => edit(t, SRC, "^\\tdepends = quickshell>=.*$", "\tdepends = quickshell"),
        1, tree => refused(`floor=missing package=quickshell want=>=${floorOf(tree, "quickshell")} ` + where())],
    ["a floored depends below its floor is refused", t => edit(t, SRC, "^\\tdepends = nodejs>=.*$", "\tdepends = nodejs>=0"),
        1, tree => refused(`floor=below package=nodejs have=>=0 want=>=${floorOf(tree, "node")} ` + where())],
    // The floor rises one past the recipe's own constraint, so the recipe is
    // below it whatever both held before.
    ["a floor bump in bin/vgsh refuses the recipes until they follow", t => {
        const bumped = constraintOf(t, "hyprland").replace(/[0-9]+$/, n => String(Number(n) + 1));
        edit(t, "bin/vgsh", "^hyprland( +)[0-9.]+ ", `hyprland$1${bumped} `);
    }, 1, tree => refused(`floor=below package=hyprland have=>=${constraintOf(tree, "hyprland")} want=>=${floorOf(tree, "hyprland")} ` + where())],
    ["a floor makes an optional core requirement required", t => edit(t, "bin/vgsh", "^(preflight_floor='\\n)", "$1fzf        0.1     ^([0-9.]+)   fzf --version\n"),
        1, () => refused("requirement=fzf package=fzf want=depends " + where())],
    ["a floor tool no requirement declares is required by its tool name", t => edit(t, "bin/vgsh", "^(preflight_floor='\\n)", "$1planted    1.0     ^([0-9.]+)   planted --version\n"),
        1, () => refused("requirement=planted package=planted want=depends " + where())],
    ["a bin/vgsh without the floor table is refused", t => edit(t, "bin/vgsh", "^preflight_floor='$", "preflight_floors='"),
        1, () => refused("floors=unreadable path=bin/vgsh")],
    ["an empty floor table is refused", t => edit(t, "bin/vgsh", "^preflight_floor='\\n[\\s\\S]*?^'$", "preflight_floor='\n'"),
        1, () => refused("floors=empty path=bin/vgsh")],
    // The agree rule.
    ["recipes with different depends are refused", t => edit(t, GIT_SRC, "^(pkgbase = vgs-git\\n)", "$1\tdepends = planted\n"),
        1, () => refused("depends=differ channel=pacman recipes=vgs,vgs-git")],
    ["recipes with different optdepends are refused", t => edit(t, GIT_SRC, "^(pkgbase = vgs-git\\n)", "$1\toptdepends = planted: a reason\n"),
        1, () => refused("optdepends=differ channel=pacman recipes=vgs,vgs-git")],
    // The pacman channel's recipe rules.
    ["a vgs pkgver other than VERSION is refused", t => write(t, "VERSION", "9.9.9\n"),
        1, tree => refused(`pkgver=${srcinfo(tree, SRC, "pkgver")} version=9.9.9 recipe=vgs`)],
    // Each checksum row sets the checksum state it tests first, so the rows
    // hold for an unpublished recipe (SKIP) and a pinned one alike.
    ["SKIP before the release tag exists passes", t => setChecksum(t, "SKIP"), 0, tree => ok(countRequirements(tree))],
    ["SKIP after the release tag exists is refused", t => {
        setChecksum(t, "SKIP");
        git("-C", t, "tag", "v" + srcinfo(t, SRC, "pkgver"));
    }, 1, tree => refused(`sha256sums=SKIP tag=v${srcinfo(tree, SRC, "pkgver")} recipe=vgs`)],
    ["a pinned sum after the release tag exists passes", t => {
        setChecksum(t, sum);
        git("-C", t, "tag", "v" + srcinfo(t, SRC, "pkgver"));
    }, 0, tree => ok(countRequirements(tree))],
    ["a sum that is not lower-case hex is refused", t => setChecksum(t, sum.toUpperCase()),
        1, () => refused(`sha256sums=${sum.toUpperCase()} recipe=vgs`)],
    ["vgs: replaces is refused", t => edit(t, SRC, "^(\\tconflicts = vgs-shell-git\\n)", "$1\treplaces = vgs-shell\n"), 1, () => refused("replaces=vgs-shell recipe=vgs")],
    ["vgs-git: replaces is refused", t => edit(t, GIT_SRC, "^(\\tconflicts = vgs-shell-git\\n)", "$1\treplaces = vgs\n"), 1, () => refused("replaces=vgs recipe=vgs-git")],
    ["vgs: a missing conflict is refused", t => edit(t, SRC, "^\\tconflicts = vgs-shell-git\\n", ""), 1, () => refused("conflicts=missing package=vgs-shell-git recipe=vgs")],
    ["vgs-git: a missing conflict is refused", t => edit(t, GIT_SRC, "^\\tconflicts = vgs\\n", ""), 1, () => refused("conflicts=missing package=vgs recipe=vgs-git")],
    ["vgs: an arch other than any is refused", t => edit(t, SRC, "^\\tarch = any$", "\tarch = x86_64"), 1, () => refused("arch=x86_64 recipe=vgs")],
    ["vgs-git: an arch other than any is refused", t => edit(t, GIT_SRC, "^\\tarch = any$", "\tarch = x86_64"), 1, () => refused("arch=x86_64 recipe=vgs-git")],
    ["vgs-git: a missing provides is refused", t => edit(t, GIT_SRC, "^\\tprovides = vgs=.*\\n", ""), 1, tree => refused(`provides=missing want=vgs=${srcinfo(tree, GIT_SRC, "pkgver")} recipe=vgs-git`)],
    ["vgs-git: a missing git makedepends is refused", t => edit(t, GIT_SRC, "^\\tmakedepends = git\\n", ""), 1, () => refused("makedepends=missing package=git recipe=vgs-git")],
    ["vgs: another source is refused", t => edit(t, SRC, "^\\tsource = (.*)$", "\tsource = $1.planted"),
        1, tree => refused(`source=${srcinfo(pristine, SRC, "source")}.planted recipe=vgs`)],
    ["vgs-git: another source is refused", t => edit(t, GIT_SRC, "^\\tsource = (.*)$", "\tsource = $1#branch=planted"),
        1, () => refused("source=vgs::git+https://github.com/vanillagreencom/vgs.git#branch=planted recipe=vgs-git")],
    // The dnf channel: the runtime dependency block is exactly the
    // requirements' set, with each floor at its epoch.
    ["dnf: a dropped Requires is refused", t => replaceIn(t, SPECS, "Requires:       git\n", ""),
        1, () => refused("requirement=git package=git want=Requires " + dnf())],
    ["dnf: an extra Requires is refused", t => replaceIn(t, SPECS, "Requires:       git\n", "Requires:       git\nRequires:       jq\n"),
        1, () => refused("extra=jq field=Requires channel=dnf recipe=vgs")],
    ["dnf: a spec floor below the preflight is refused", t => { for (const spec of SPECS) edit(t, spec, "^(Requires:\\s+quickshell >= ).*$", "$10"); },
        1, tree => refused(`floor=mismatch package=quickshell have=0 want=${floorOf(tree, "quickshell")} ` + dnf())],
    ["dnf: a spec floor with no version is refused", t => { edit(t, REL, "^(Requires:\\s+hyprland) >= .*$", "$1"); edit(t, GIT, "^(Requires:\\s+hyprland) >= .*$", "$1"); },
        1, tree => refused(`floor=mismatch package=hyprland have=none want=${floorOf(tree, "hyprland")} ` + dnf())],
    // The Arch recipes follow the raised floor, so the dnf channel is the one
    // that refuses.
    ["dnf: a raised preflight floor is refused", t => {
        const bumped = specFloor(t, REL, "quickshell").replace(/[0-9]+$/, n => String(Number(n) + 1));
        edit(t, "bin/vgsh", "^quickshell( +)[0-9.]+ ", `quickshell$1${bumped} `);
        for (const recipe of ["vgs", "vgs-git"]) edit(t, `packaging/arch/${recipe}/.SRCINFO`, "^\\tdepends = quickshell>=.*$", "\tdepends = quickshell>=" + bumped);
    }, 1, tree => refused(`floor=mismatch package=quickshell have=${specFloor(tree, REL, "quickshell")} want=${floorOf(tree, "quickshell")} ` + dnf())],
    ["dnf: an explicit epoch 0 on a floor passes", t => { edit(t, REL, "^(Requires:\\s+hyprland >= )", "$10:"); edit(t, GIT, "^(Requires:\\s+hyprland >= )", "$10:"); },
        0, tree => ok(countRequirements(tree))],
    ["dnf: a node floor without its epoch is refused", t => { edit(t, REL, "^(Requires:\\s+nodejs >= )1:", "$1"); edit(t, GIT, "^(Requires:\\s+nodejs >= )1:", "$1"); },
        1, () => refused("epoch=mismatch package=nodejs have=0 want=1 " + dnf())],
    ["dnf: a node floor with another epoch is refused", t => { edit(t, REL, "^(Requires:\\s+nodejs >= )1:", "$12:"); edit(t, GIT, "^(Requires:\\s+nodejs >= )1:", "$12:"); },
        1, () => refused("epoch=mismatch package=nodejs have=2 want=1 " + dnf())],
    ["dnf: an epoch on an epoch-0 package is refused", t => { edit(t, REL, "^(Requires:\\s+quickshell >= )", "$11:"); edit(t, GIT, "^(Requires:\\s+quickshell >= )", "$11:"); },
        1, () => refused("epoch=mismatch package=quickshell have=1 want=0 " + dnf())],
    ["dnf: an optional requirement as Requires is refused", t => replaceIn(t, SPECS, "Recommends:     gum\n", "Requires:       gum\n"),
        1, () => refused("requirement=gum package=gum want=Recommends " + dnf())],
    ["dnf: an extra Recommends is refused", t => replaceIn(t, SPECS, "Recommends:     fzf\n", "Recommends:     fzf\nRecommends:     jq\n"),
        1, () => refused("extra=jq field=Recommends channel=dnf recipe=vgs")],
    ["dnf: a renamed dnf package is refused", t => {
        const file = path.join(t, "config/requirements.json");
        const data = JSON.parse(fs.readFileSync(file, "utf8"));
        const hits = data.filter(r => r.command === "node");
        if (hits.length !== 1) throw new Error("rename: refused: node requirements=" + hits.length);
        hits[0].packages.dnf = "nodejs22";
        fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
    }, 1, () => refused("requirement=node package=nodejs22 want=Requires " + dnf())],
    ["dnf: a plugin's optional requirement must be recommended", t => addRequirement(t, firstPlugin(t), "hyprpicker", { dnf: "hyprpicker" }, true),
        1, tree => refused("requirement=hyprpicker package=hyprpicker want=Recommends " + dnf("vgs", firstPlugin(tree)))],
    ["dnf: a plugin's required requirement must be required", t => addRequirement(t, firstPlugin(t), "grim", { dnf: "grim" }, false),
        1, tree => refused("requirement=grim package=grim want=Requires " + dnf("vgs", firstPlugin(tree)))],
    ["dnf: a requirement with no dnf package has no Fedora line", t => addRequirement(t, firstPlugin(t), "checkupdates", { pacman: "pacman-contrib" }, true),
        0, tree => ok(countRequirements(tree))],
    ["dnf: an unreadable dependency line is refused", t => { edit(t, REL, "^(Requires:\\s+quickshell) >= ", "$1 > "); edit(t, GIT, "^(Requires:\\s+quickshell) >= ", "$1 > "); },
        1, tree => refused("line=unreadable spec=vgs.spec text=Requires:       quickshell > " + fs.readFileSync(path.join(tree, REL), "utf8").match(/^Requires:\s+quickshell > (\S+)$/m)[1])],
    // The same lines in another order: the dependency sets agree, the blocks
    // do not.
    ["dnf: blocks that differ are refused", t => replaceIn(t, [REL], "Recommends:     gum\nRecommends:     fzf\n", "Recommends:     fzf\nRecommends:     gum\n"),
        1, () => refused("block=differs specs=vgs.spec,vgs-git.spec")],
    ["dnf: a missing block marker is refused", t => replaceIn(t, [GIT], "# end runtime dependencies\n", ""),
        1, () => refused("block=missing spec=vgs-git.spec")],
    ["dnf: a Version off VERSION is refused", t => edit(t, REL, "^(Version:\\s+).*$", "$19.9.9"),
        1, tree => refused(`version=mismatch spec=vgs.spec have=9.9.9 want=${fs.readFileSync(path.join(tree, "VERSION"), "utf8").trim()}`)],
    ["dnf: a changelog entry off the version is refused", t => edit(t, REL, "^(\\* .* - )[^\\s]+$", "$10.0.0-1"),
        1, tree => refused(`changelog=mismatch spec=vgs.spec want=...- ${specValue(tree, REL, "Version")}-${specValue(tree, REL, "Release").replace("%{?dist}", "")} have=${specValue(tree, REL, "*")}`)],
    ["dnf: vgs-git without its vgs provide is refused", t => replaceIn(t, [GIT], "Provides:       vgs = %{version}\n", ""),
        1, () => refused("provides=missing spec=vgs-git.spec want=vgs = %{version}")],
    ["dnf: vgs-git without its vgs conflict is refused", t => replaceIn(t, [GIT], "Conflicts:      vgs\n", ""),
        1, () => refused("conflicts=missing spec=vgs-git.spec want=vgs")],
    ["dnf: a vgs-git changelog entry is refused", t => replaceIn(t, [GIT], "\n%changelog\n", "\n%changelog\n* Mon Sep 28 2026 A <a@b> - 0-1\n- x\n"),
        1, () => refused("changelog=entries spec=vgs-git.spec")],
    ["dnf: an arch-bound spec is refused", t => replaceIn(t, [REL], "BuildArch:      noarch", "BuildArch:      x86_64"),
        1, () => refused("buildarch=x86_64 spec=vgs.spec want=noarch")],
    ["dnf: a licence that differs is refused", t => edit(t, GIT, "^(License:\\s+).*$", "$1MIT"),
        1, () => refused("tag=differs name=License specs=vgs.spec,vgs-git.spec")],
    ["dnf: an install section that differs is refused", t => replaceIn(t, [GIT], "PREFIX=%{_prefix} packaging/install-system.sh", "PREFIX=/usr/local packaging/install-system.sh"),
        1, () => refused("section=differs name=%install specs=vgs.spec,vgs-git.spec")],
    ["dnf: an install off the shared installer is refused", t => replaceIn(t, SPECS, "DESTDIR=%{buildroot} PREFIX=%{_prefix} packaging/install-system.sh", "make install"),
        1, () => refused("install=missing want=DESTDIR=%{buildroot} PREFIX=%{_prefix} packaging/install-system.sh")],
    ["dnf: a check off the manifest checker is refused", t => replaceIn(t, SPECS, "scripts/check-install-tree.sh %{buildroot} %{_prefix}", "true"),
        1, () => refused("check=missing want=scripts/check-install-tree.sh %{buildroot} %{_prefix}")],
    ["dnf: a renamed package is refused", t => replaceIn(t, [REL], "Name:           vgs\n", "Name:           vgs2\n"),
        1, () => refused("name=mismatch spec=vgs.spec have=vgs2 want=vgs")],
    // The requirement read never passes empty.
    ["an unparsable core requirement file is refused", t => write(t, "config/requirements.json", "[\n"),
        1, () => refused("requirements=unreadable path=config/requirements.json")],
    ["a core list the judge refuses is refused", t => edit(t, "config/requirements.json", '"command": "node"', '"command": "node planted"'),
        1, () => refused("requirements=refused path=config/requirements.json")],
    ["an empty core list is refused", t => write(t, "config/requirements.json", "[]\n"), 1, () => refused("requirements=empty scope=core")],
    // Without makepkg every other rule still judges, and a clean tree is not
    // measured rather than passed.
    ["without makepkg a passing tree is not measured", () => {}, 77, () => "check-packaging: status=not-measured reason=makepkg-missing channel=pacman", farm],
    ["an unknown argument is refused", () => {}, 2, () => refused("argument=--bogus"), undefined, ["--bogus"]],
    ["--root without a directory is refused", () => {}, 2, () => refused("argument=--root"), undefined, ["--root"]],
    // A data root whose own judge and scan would refuse still passes: both
    // come from the checker's repository.
    ["the judge and the scan load from the checker's repository", t => {
        if (fs.existsSync(path.join(t, "shell/Core")) || fs.existsSync(path.join(t, "bin/lib"))) throw new Error("data root: refused: code=present");
        fs.mkdirSync(path.join(t, "shell/Core"), { recursive: true });
        fs.mkdirSync(path.join(t, "bin/lib"), { recursive: true });
        fs.writeFileSync(path.join(t, "shell/Core/PluginLogic.js"), "planted: not a library\n");
        fs.writeFileSync(path.join(t, "bin/lib/qml-library.js"), "throw new Error('planted loader');\n");
        fs.writeFileSync(path.join(t, "bin/vgsh-scan"), "#!/bin/sh\nexit 9\n", { mode: 0o755 });
    }, 0, tree => ok(countRequirements(tree))],
    ["without makepkg a refused rule still fails", t => edit(t, SRC, "^\\tarch = any$", "\tarch = x86_64"), 1, () => refused("arch=x86_64 recipe=vgs"), farm],
];

let failures = 0;
ROWS.forEach(([name, setup, wantExit, wantLine, pathValue, args], i) => {
    let status, first, out = "";
    try {
        const tree = i === 0 ? pristine : fresh("row-" + i);
        setup(tree);
        const run = childProcess.spawnSync(process.execPath, [path.join(repo, "scripts/check-packaging.js"), ...(args || ["--root", tree])], { encoding: "utf8", env: { ...ENV, PATH: pathValue || basePath } });
        out = run.stdout + run.stderr;
        status = run.status;
        first = run.stdout.split("\n")[0];
        if (status === wantExit && first === wantLine(tree)) {
            console.log("  ok    " + name);
            return;
        }
        console.log(`  FAIL  ${name}: exit=${status} want=${wantExit} first=[${first}] want=[${wantLine(tree)}]`);
    } catch (e) {
        console.log(`  FAIL  ${name}: ${e.message}`);
    }
    failures += 1;
    if (out !== "") console.log(out.replace(/^/gm, "        "));
});
if (failures > 0) {
    console.log("test-check-packaging: failed=" + failures);
    process.exit(1);
}
console.log("test-check-packaging: ok");
