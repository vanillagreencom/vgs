#!/usr/bin/env node
// Controls for tools/convert-v1-themes. The suite converts two fixture v1
// themes, compares the output with checked-in expected packages and
// thumbnails, runs the catalog judge, and plants one defect for each
// converter guard. Mutant controls edit a copy of the converter and assert
// their substitution matched.
"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const zlib = require("node:zlib");

const repo = path.join(__dirname, "..");
const FIXTURE = path.join(repo, "scripts", "fixtures", "convert-v1-themes");
const CONVERTER = path.join(repo, "tools", "convert-v1-themes");
const JUDGE = path.join(repo, "bin", "vgsh-theme-judge");
const NODE = process.execPath;

function rmTree(dir) {
    fs.rmSync(dir, { recursive: true, force: true });
}

function cpTree(from, to) {
    fs.cpSync(from, to, { recursive: true, dereference: false });
}

function env(root) {
    const home = path.join(root, "home");
    const tmp = path.join(root, "tmp");
    const magickTmp = path.join(root, "magick-tmp");
    for (const dir of [home, tmp, magickTmp]) fs.mkdirSync(dir, { recursive: true });
    return { PATH: process.env.PATH, HOME: home, XDG_CACHE_HOME: path.join(root, "xdg-cache"), TMPDIR: tmp, MAGICK_TEMPORARY_PATH: magickTmp, LC_ALL: "C" };
}

function runTool(root, extra = [], tool = CONVERTER) {
    const archiveBase = pathToFileUrl(path.join(FIXTURE, "archives"));
    return spawnSync(NODE, [tool, path.join(root, "v1"), "--theme", "beta", "--theme", "alpha", "--catalog-dir", path.join(root, "themes", "catalog"), "--asset-cache", path.join(root, "cache"), "--asset-base", archiveBase, "--allow-file-base", ...extra], { encoding: "utf8", env: env(root) });
}

function pathToFileUrl(file) {
    return new URL("file://" + path.resolve(file).split(path.sep).map(encodeURIComponent).join("/")).toString();
}

function freshRoot(root) {
    cpTree(path.join(FIXTURE, "v1"), path.join(root, "v1"));
    fs.mkdirSync(path.join(root, "themes"), { recursive: true });
}

function filesUnder(dir) {
    const out = [];
    const walk = rel => {
        const at = path.join(dir, rel);
        for (const entry of fs.readdirSync(at, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
            const child = path.join(rel, entry.name);
            if (entry.isDirectory()) walk(child);
            else out.push(child);
        }
    };
    walk("");
    return out;
}

function compareDirs(actual, expected) {
    assert.deepEqual(filesUnder(actual), filesUnder(expected), "file list");
    for (const rel of filesUnder(expected)) {
        assert.deepEqual(fs.readFileSync(path.join(actual, rel)), fs.readFileSync(path.join(expected, rel)), rel);
    }
}

function digestDir(dir) {
    const hash = crypto.createHash("sha256");
    for (const rel of filesUnder(dir)) {
        hash.update(rel);
        hash.update("\0");
        hash.update(fs.readFileSync(path.join(dir, rel)));
        hash.update("\0");
    }
    return hash.digest("hex");
}

function updatePins(root, theme, edit) {
    const catalogFile = path.join(root, "v1", "themes", "catalog.json");
    const lockFile = path.join(root, "v1", "themes", "asset-lock.json");
    const catalog = JSON.parse(fs.readFileSync(catalogFile, "utf8"));
    const lock = JSON.parse(fs.readFileSync(lockFile, "utf8"));
    const entry = catalog.themes.find(item => item.name === theme);
    edit(entry.assets, lock.themes[theme], entry);
    entry.size = entry.assets.size;
    catalog.totalSize = catalog.themes.reduce((sum, item) => sum + item.size, 0);
    fs.writeFileSync(catalogFile, JSON.stringify(catalog, null, 2) + "\n");
    fs.writeFileSync(lockFile, JSON.stringify(lock, null, 2) + "\n");
}

function makeTarGz(entries) {
    const blocks = [];
    const checksum = header => {
        for (let i = 148; i < 156; i++) header[i] = 32;
        let sum = 0;
        for (const byte of header) sum += byte;
        header.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, 8, "ascii");
    };
    for (const entry of entries) {
        const data = Buffer.from(entry.data || "");
        const header = Buffer.alloc(512);
        header.write(entry.name, 0, 100, "utf8");
        header.write("0000644\0", 100, 8, "ascii");
        header.write("0000000\0", 108, 8, "ascii");
        header.write("0000000\0", 116, 8, "ascii");
        header.write((entry.type === "2" ? 0 : data.length).toString(8).padStart(11, "0") + "\0", 124, 12, "ascii");
        header.write("00000000000\0", 136, 12, "ascii");
        header.write(entry.type || "0", 156, 1, "ascii");
        if (entry.link) header.write(entry.link, 157, 100, "utf8");
        header.write("ustar\0", 257, 6, "ascii");
        header.write("00", 263, 2, "ascii");
        checksum(header);
        blocks.push(header);
        if (entry.type !== "2") {
            blocks.push(data);
            const pad = (512 - (data.length % 512)) % 512;
            if (pad > 0) blocks.push(Buffer.alloc(pad));
        }
    }
    blocks.push(Buffer.alloc(1024));
    return zlib.gzipSync(Buffer.concat(blocks), { mtime: 0 });
}

function replaceArchive(root, theme, entries) {
    const archive = path.join(root, "archives", "themes-v1", `vgs-theme-${theme}-r1.tar.gz`);
    fs.mkdirSync(path.dirname(archive), { recursive: true });
    const bytes = makeTarGz(entries);
    fs.writeFileSync(archive, bytes);
    const sha = crypto.createHash("sha256").update(bytes).digest("hex");
    updatePins(root, theme, (catalog, lock) => {
        catalog.size = bytes.length;
        catalog.sha256 = sha;
        lock.size = bytes.length;
        lock.sha256 = sha;
    });
}

function copyFixtureArchives(root) {
    cpTree(path.join(FIXTURE, "archives"), path.join(root, "archives"));
}

function runWithRoot(root, extra = [], tool = CONVERTER) {
    const archiveBase = pathToFileUrl(path.join(root, "archives"));
    return spawnSync(NODE, [tool, path.join(root, "v1"), "--theme", "beta", "--theme", "alpha", "--catalog-dir", path.join(root, "themes", "catalog"), "--asset-cache", path.join(root, "cache"), "--asset-base", archiveBase, "--allow-file-base", ...extra], { encoding: "utf8", env: env(root) });
}

function assertRefuses(root, mutate, want) {
    freshRoot(root);
    copyFixtureArchives(root);
    mutate(root);
    const proc = runWithRoot(root);
    assert.equal(proc.status, 1, proc.stdout + proc.stderr);
    assert.ok(proc.stderr.split("\n")[0].includes(want), `want ${want}, got ${proc.stderr}`);
}

function converterCopy(root, needle, replacement) {
    const source = fs.readFileSync(CONVERTER, "utf8");
    assert.equal(source.split(needle).length, 2, `control needle must occur once: ${needle}`);
    fs.mkdirSync(path.join(root, "copy", "tools"), { recursive: true });
    for (const link of ["bin", "shell"]) fs.symlinkSync(path.join(repo, link), path.join(root, "copy", link));
    const copy = path.join(root, "copy", "tools", "convert-v1-themes");
    fs.writeFileSync(copy, source.replace(needle, replacement));
    return copy;
}

function assertMutantFails(root, label, needle, replacement) {
    freshRoot(root);
    copyFixtureArchives(root);
    const copy = converterCopy(root, needle, replacement);
    const proc = runWithRoot(root, [], copy);
    assert.equal(proc.status, 0, `${label}: ${proc.stdout}${proc.stderr}`);
    let failed = false;
    try {
        compareDirs(path.join(root, "themes", "catalog"), path.join(FIXTURE, "expected", "catalog"));
    } catch (_) {
        failed = true;
    }
    assert.equal(failed, true, `${label}: mutant matched expected output`);
}

fs.mkdirSync(path.join(repo, "tmp"), { recursive: true });
const root = fs.mkdtempSync(path.join(repo, "tmp", "test-convert-v1-themes-"));
let failures = 0;
function row(name, fn) {
    try {
        fn(path.join(root, name.replace(/[^A-Za-z0-9_.-]/g, "-")));
        console.log(`  ok    ${name}`);
    } catch (e) {
        failures += 1;
        console.error(`  FAIL  ${name}`);
        console.error(String(e.stack || e).split("\n").map(line => `        ${line}`).join("\n"));
    }
}

try {
    row("converts fixtures and the catalog judge accepts them", dir => {
        freshRoot(dir);
        copyFixtureArchives(dir);
        const proc = runWithRoot(dir);
        assert.equal(proc.status, 0, proc.stdout + proc.stderr);
        compareDirs(path.join(dir, "themes", "catalog"), path.join(FIXTURE, "expected", "catalog"));
        const judged = spawnSync(NODE, [JUDGE, "catalog-check", path.join(dir, "themes")], { encoding: "utf8", env: env(dir) });
        assert.equal(judged.status, 0, judged.stdout + judged.stderr);
        const before = digestDir(path.join(dir, "themes", "catalog"));
        const again = runWithRoot(dir);
        assert.equal(again.status, 0, again.stdout + again.stderr);
        assert.equal(digestDir(path.join(dir, "themes", "catalog")), before, "rerun changed output");
    });

    const refusals = [
        ["sha256 mismatch", rootDir => updatePins(rootDir, "alpha", (catalog, lock) => { catalog.sha256 = "0".repeat(64); lock.sha256 = "0".repeat(64); }), "asset-sha256"],
        ["size mismatch", rootDir => updatePins(rootDir, "alpha", (catalog, lock) => { catalog.size += 1; lock.size += 1; }), "asset-size"],
        ["pin disagreement", rootDir => updatePins(rootDir, "alpha", (_catalog, lock) => { lock.size += 1; }), "theme=alpha key=pin.size"],
        ["bad colors line", rootDir => fs.appendFileSync(path.join(rootDir, "v1", "themes", "alpha", "colors.toml"), "not a colour\n"), "theme=alpha key=colors.toml"],
        ["missing color key", rootDir => {
            const file = path.join(rootDir, "v1", "themes", "alpha", "colors.toml");
            fs.writeFileSync(file, fs.readFileSync(file, "utf8").replace(/^color4 = .*\n/m, ""));
        }, "theme=alpha key=colors.toml.color4 reason=missing"],
        ["unsafe archive symlink", rootDir => replaceArchive(rootDir, "alpha", [{ name: "backgrounds/link.jpg", type: "2", link: "../x" }]), "theme=alpha key=archive.member"],
        ["over budget thumbnail", _rootDir => {}, "key=thumbnail reason=over-budget"]
    ];
    for (const [name, mutate, want] of refusals) {
        row(name, dir => {
            if (name === "over budget thumbnail") {
                freshRoot(dir);
                copyFixtureArchives(dir);
                const proc = runWithRoot(dir, ["--thumbnail-budget", "1"]);
                assert.equal(proc.status, 1, proc.stdout + proc.stderr);
                assert.ok(proc.stderr.includes(want), proc.stderr);
                return;
            }
            assertRefuses(dir, mutate, want);
        });
    }

    row("terminal overlay control", dir => assertMutantFails(dir, "terminal overlay", "slots[slot] = terminalOverrides[slot] || colors[slot];", "slots[slot] = colors[slot];"));
    row("first image control", dir => assertMutantFails(dir, "first image", "const first = backgrounds.firstImageName(entries);", "const first = entries.map(entry => entry.name).sort().pop() || null;"));
    row("deterministic index control", dir => assertMutantFails(dir, "deterministic index", "entries: Array.from(byName.values()).sort((a, b) => a.name.localeCompare(b.name))", "entries: Array.from(byName.values())"));
} finally {
    rmTree(root);
}

if (failures > 0) process.exit(1);
console.log("test-convert-v1-themes: ok");
