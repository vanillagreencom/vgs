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
const { spawn, spawnSync } = require("node:child_process");

const { paxRecord, makeTarGz } = require("./tar-fixture.js");

const repo = path.join(__dirname, "..");
const FIXTURE = path.join(repo, "scripts", "fixtures", "convert-v1-themes");
const CONVERTER = path.join(repo, "tools", "convert-v1-themes");
const JUDGE = path.join(repo, "bin", "vgsh-theme-judge");
const CONTRAST = path.join(repo, "scripts", "check-theme-contrast.js");
const NODE = process.execPath;
const MAGICK = findOnPath("magick");
const FLOCK = findOnPath("flock");
const TEST_PATH = Array.from(new Set([path.dirname(NODE), path.dirname(MAGICK), path.dirname(FLOCK)])).join(path.delimiter);
const TLS_KEY = `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDP29gb/Ka2HUVG
XsVeQGSQxtfEF94aWUGszUgb/GIEZL/luPXGYbbrBR0iAH0HHh8E7Muik6OpsfXT
E5oO4OYey9aOlMajEuQ9JnssKz16R3fNImhI9kdcyB/0adp+4dV11ISB4xfBQpqj
1bS5UTEFBz7zc9nM2vZNYYm/e6sHl3LPiJIOFYPZ85iwBoODrKHElSgSJLHmwyDL
ExZyEHpC3SXdPTQEuZw1riRzhGTjUFGR2eENfqonBYIhGKyqCCTqYxuqb/f4iuRq
23ltV8WmEyk/TkC4nDQRWNXW0Mq3tX2aKELcNgbzbRFma/v6NJPsSnV/JaOK/NyZ
j+uKX6TPAgMBAAECggEAYE+m6ozeOEsGwsz92aavkk+4QUGn5YCPCEEUFPeT+SIv
soNJylKTfYFgltUwGYCw8cjAsEOFlYcCdvvBqfw2VHWxpF42TfBediEi+HvOoB6G
WbQEKy6GMWz/NXJozdrZXCANB9wQMTmpypkmhKmks4ZAenCnLh8U+hTkTSfBvyFt
LkmyNnaEHEKBAQpkfjc1VesmiNYpt3dbb4jnpsb0cMRg3P+jNuQh0P5dJCfuXWfZ
BeXEJlWIf6Y/Vjr6xe+c1HDNh0mVWsI4qAc35tcwUoXzV98kpLxxQSCCuJkafHKp
WgObHg3E3lUThUxj+6gS+2O+LXdkjef/cimtr6S6cQKBgQDuDlhoSBiIFLoirCk/
hwk7saS0dAQWYKv0MmCm7giaPTW8hg5FR3y1Bpb7mIjp68RqpUrP7zsMJJsoBmGb
R1E7ZdvWNJN4N2bD+7LkJV9zxOwjOAywV/O7BVFew84p5TKl6qW3BndGEhURNCN0
OXZGdY1Spu4DHNntlD/1MyFonwKBgQDfhsvhSbgEuJpv7ZI204FDis9340Rk1LLZ
iIDwgtdYD1M4hGuopALq28fB3JrFgEJy9m68cWk7CSHhcfzQ+n7Parnpo/uX2YZ2
kJ6fBIbIZ3Q0V4i+1YB99QMYZGThAZw090G5ZkwFduYD7YsFsYJewCPRLqyQVHhH
jPbFQJ3l0QKBgGw4R0Z45/YM/iU/AK1plO/3LPn/98+4eNNVh4y7j1uW0fP3OUuT
WQTujvqneC5nSO52YBExHzXA+mvyorK1dB89iffSBOxUuzoDFWsT9lWpwvOrylDs
Wte9biVXfESddi3pAxa2MMjA9aTRgACZEsSrMejODEuL9SJFD+JHMTvfAoGBANYi
LSia1aX4L0LwpXTOc/P/g7dHShsKRHfutA80WRXsQH5RJU2+KWlSuO/35XE06PN3
LyhpwTSkEAgIifitMFSF2qp/xKN46L6m1r5huLk9mm4WOVMP93MzCA8TBi0jvMBk
6lqxLDzD5aB3rQn8PneEvAtGGlx9/2gUG8dlmp4xAoGAfP5K+xXPf/G8C0l34ISm
pm1fwh2wURg1DltiCpY0EZ8aQOutvjNvE20P2aydggGA8RUi3cDYHquzNJJ0X+TM
tqgCmtp26cLRvY1MM6mQLn4aWSUhVwWcDnNrivkuoSUZp9FAVo28b3G0GU2hPa8F
GamDm52bnMxZTC1D+Te7q4A=
-----END PRIVATE KEY-----`;
const TLS_CERT = `-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgIUNSNpUVl/G66DQ7y1tCPfug1TjgUwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MDkyOTA0MzMxNloXDTI2MDkz
MDA0MzMxNlowFDESMBAGA1UEAwwJMTI3LjAuMC4xMIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAz9vYG/ymth1FRl7FXkBkkMbXxBfeGllBrM1IG/xiBGS/
5bj1xmG26wUdIgB9Bx4fBOzLopOjqbH10xOaDuDmHsvWjpTGoxLkPSZ7LCs9ekd3
zSJoSPZHXMgf9GnafuHVddSEgeMXwUKao9W0uVExBQc+83PZzNr2TWGJv3urB5dy
z4iSDhWD2fOYsAaDg6yhxJUoEiSx5sMgyxMWchB6Qt0l3T00BLmcNa4kc4Rk41BR
kdnhDX6qJwWCIRisqggk6mMbqm/3+Irkatt5bVfFphMpP05AuJw0EVjV1tDKt7V9
mihC3DYG820RZmv7+jST7Ep1fyWjivzcmY/ril+kzwIDAQABo1MwUTAdBgNVHQ4E
FgQUr47aaXjNFb1Dzl4E+rb9qTRLoWMwHwYDVR0jBBgwFoAUr47aaXjNFb1Dzl4E
+rb9qTRLoWMwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAd6hR
EfOzVMxdyx/XaiU66H6otK83Ppm8W34tdTC53P88imByUxO0hzQgoGGoBNKiBb1E
t0CMZsRuTivobxB3mmYr93WM3aHjjotThwSX4akMTL9CJt/od3kniEm+u0Kx3RG6
PrpzcZhDcF1UGPwFLBvyeALgwCrJ/kzU6J4l/VVcMPrNd6IXd/jhzivhYYSKwWaW
rrhqYONzwMruH6oeGzouEQEthMuCl6KLOaov6fb7CWf5Vk13cmvk4RFkE1UkIBDm
TOpsuYdxogB6TtSx0ruDVj30ymi+bM3qaOqw3oUEizPVsiTMwiPkp5lG94WbXlBJ
AewtjlpODDh4IvOZQQ==
-----END CERTIFICATE-----`;

function rmTree(dir) {
    fs.rmSync(dir, { recursive: true, force: true });
}

function findOnPath(command) {
    for (const dir of (process.env.PATH || "").split(path.delimiter)) {
        const file = path.join(dir, command);
        if (fs.existsSync(file)) return file;
    }
    throw new Error(`${command} not found on PATH`);
}

function cpTree(from, to) {
    fs.cpSync(from, to, { recursive: true, dereference: false });
}

function env(root, extra = {}) {
    const home = path.join(root, "home");
    const tmp = path.join(root, "tmp");
    const magickTmp = path.join(root, "magick-tmp");
    const runtime = path.join(root, "runtime");
    for (const dir of [home, tmp, magickTmp, runtime]) fs.mkdirSync(dir, { recursive: true });
    return Object.assign({ PATH: TEST_PATH, HOME: home, XDG_CACHE_HOME: path.join(root, "xdg-cache"), XDG_RUNTIME_DIR: runtime, TMPDIR: tmp, MAGICK_TEMPORARY_PATH: magickTmp, LC_ALL: "C" }, extra);
}

function pathToFileUrl(file) {
    return new URL("file://" + path.resolve(file).split(path.sep).map(encodeURIComponent).join("/")).toString();
}

function codeUnitCompare(a, b) {
    return a < b ? -1 : a > b ? 1 : 0;
}

function freshRoot(root) {
    cpTree(path.join(FIXTURE, "v1"), path.join(root, "v1"));
    fs.mkdirSync(path.join(root, "themes"), { recursive: true });
}

function filesUnder(dir) {
    const out = [];
    const walk = rel => {
        const at = path.join(dir, rel);
        for (const entry of fs.readdirSync(at, { withFileTypes: true }).sort((a, b) => codeUnitCompare(a.name, b.name))) {
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

function runThemes(root, themes, extra = [], tool = CONVERTER, envExtra = {}) {
    const archiveBase = pathToFileUrl(path.join(root, "archives"));
    const selection = themes.flatMap(theme => ["--theme", theme]);
    return spawnSync(NODE, [tool, path.join(root, "v1"), ...selection, "--catalog-dir", path.join(root, "themes", "catalog"), "--asset-cache", path.join(root, "cache"), "--asset-base", archiveBase, "--allow-file-base", ...extra], { encoding: "utf8", env: env(root, envExtra) });
}

function runWithRoot(root, extra = [], tool = CONVERTER, envExtra = {}) {
    return runThemes(root, ["beta", "alpha"], extra, tool, envExtra);
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

function assertPreservesUnselected(root, tool = CONVERTER) {
    freshRoot(root);
    copyFixtureArchives(root);
    let proc = runThemes(root, ["alpha"], [], tool);
    assert.equal(proc.status, 0, proc.stdout + proc.stderr);
    proc = runThemes(root, ["beta"], [], tool);
    assert.equal(proc.status, 0, proc.stdout + proc.stderr);
    const index = JSON.parse(fs.readFileSync(path.join(root, "themes", "catalog", "index.json"), "utf8"));
    assert.deepEqual(index.entries.map(entry => entry.name), ["alpha", "beta"]);
    for (const theme of ["alpha", "beta"]) {
        assert.equal(fs.existsSync(path.join(root, "themes", "catalog", theme, "theme.json")), true, `${theme} theme.json`);
        assert.equal(fs.existsSync(path.join(root, "themes", "catalog", "thumbnails", `${theme}.jpg`)), true, `${theme} thumbnail`);
    }
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

function sampleImage() {
    return fs.readFileSync(path.join(FIXTURE, "expected", "catalog", "thumbnails", "alpha.jpg"));
}

function startRedirectServer(root) {
    const script = path.join(root, "redirect-server.js");
    const portFile = path.join(root, "redirect-port");
    fs.writeFileSync(script, `
const fs = require('node:fs');
const https = require('node:https');
const key = ${JSON.stringify(TLS_KEY)};
const cert = ${JSON.stringify(TLS_CERT)};
const server = https.createServer({ key, cert }, (_req, res) => {
  res.writeHead(302, { Location: 'http://127.0.0.1/plain.tar.gz' });
  res.end();
});
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(${JSON.stringify(portFile)}, String(server.address().port));
});
`);
    return { child: spawn(NODE, [script], { stdio: ["ignore", "ignore", "pipe"], env: env(root) }), portFile };
}

function waitForPort(server) {
    const marker = new Int32Array(new SharedArrayBuffer(4));
    for (let i = 0; i < 200; i++) {
        if (fs.existsSync(server.portFile)) return Number(fs.readFileSync(server.portFile, "utf8"));
        Atomics.wait(marker, 0, 0, 10);
    }
    throw new Error("redirect server did not start");
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
        const contrast = spawnSync(NODE, [CONTRAST, path.join(dir, "themes")], { encoding: "utf8", env: env(dir) });
        assert.equal(contrast.status, 0, contrast.stdout + contrast.stderr);
        const beta = JSON.parse(fs.readFileSync(path.join(dir, "themes", "catalog", "beta", "theme.json"), "utf8"));
        assert.equal(beta.tokens.color.textFaint, "mix({palette.foreground}, {palette.background}, 0.37)");
        assert.equal(beta.tokens.color.success, "mix({palette.success}, contrast({palette.background}), 0.28)");
        const before = digestDir(path.join(dir, "themes", "catalog"));
        const again = runWithRoot(dir);
        assert.equal(again.status, 0, again.stdout + again.stderr);
        assert.equal(digestDir(path.join(dir, "themes", "catalog")), before, "rerun changed output");
    });

    row("accent override updates palette and index", dir => {
        freshRoot(dir);
        copyFixtureArchives(dir);
        const proc = runThemes(dir, ["accent"]);
        assert.equal(proc.status, 0, proc.stdout + proc.stderr);
        assert.match(proc.stdout, /overrides=palette\.accent/);
        const theme = JSON.parse(fs.readFileSync(path.join(dir, "themes", "catalog", "accent", "theme.json"), "utf8"));
        const index = JSON.parse(fs.readFileSync(path.join(dir, "themes", "catalog", "index.json"), "utf8"));
        assert.equal(theme.tokens.palette.accent, "#838084");
        assert.equal(index.entries[0].palette.accent, "#838084");
        const contrast = spawnSync(NODE, [CONTRAST, path.join(dir, "themes")], { encoding: "utf8", env: env(dir) });
        assert.equal(contrast.status, 0, contrast.stdout + contrast.stderr);
    });

    row("accent override controls", dir => {
        freshRoot(dir);
        copyFixtureArchives(dir);
        const noAccent = converterCopy(path.join(dir, "no-accent"), "const COLOR_OVERRIDE_ORDER = [\"accent\", \"textMuted\", \"textFaint\", \"success\", \"warning\", \"danger\", \"info\"];", "const COLOR_OVERRIDE_ORDER = [\"textMuted\", \"textFaint\", \"success\", \"warning\", \"danger\", \"info\"];");
        const noAccentDir = path.join(dir, "no-accent-run");
        freshRoot(noAccentDir);
        copyFixtureArchives(noAccentDir);
        const refused = runThemes(noAccentDir, ["accent"], [], noAccent);
        assert.equal(refused.status, 0, refused.stdout + refused.stderr);
        assert.match(refused.stdout, /held-back theme=accent text=color\.accent/, "accent was still fixable without its role");

        const staleIndex = converterCopy(path.join(dir, "stale-index"), "palette: paletteForEntry(theme, readability.shell)", "palette");
        const staleIndexDir = path.join(dir, "stale-index-run");
        freshRoot(staleIndexDir);
        copyFixtureArchives(staleIndexDir);
        const mismatch = runThemes(staleIndexDir, ["accent"], [], staleIndex);
        assert.equal(mismatch.status, 1, mismatch.stdout + mismatch.stderr);
        assert.match(mismatch.stderr, /catalog-palette-mismatch/);

        const smallestNeedle = "if (roleShortfall(initialShortfalls, \"accent\") !== undefined) {\n        let chosen = null;\n        for (let step = 1; step <= 100; step++)";
        const largestAccent = converterCopy(path.join(dir, "largest-accent"), smallestNeedle, "if (roleShortfall(initialShortfalls, \"accent\") !== undefined) {\n        let chosen = null;\n        for (let step = 100; step >= 1; step--)");
        const mutantDir = path.join(dir, "largest-accent-run");
        freshRoot(mutantDir);
        copyFixtureArchives(mutantDir);
        const mutant = runThemes(mutantDir, ["accent"], [], largestAccent);
        assert.equal(mutant.status, 0, mutant.stdout + mutant.stderr);
        const mutantTheme = JSON.parse(fs.readFileSync(path.join(mutantDir, "themes", "catalog", "accent", "theme.json"), "utf8"));
        assert.notEqual(mutantTheme.tokens.palette.accent, "#838084");
    });

    row("muted and faint overrides keep the fade hierarchy", dir => {
        freshRoot(dir);
        copyFixtureArchives(dir);
        const proc = runThemes(dir, ["muted"]);
        assert.equal(proc.status, 0, proc.stdout + proc.stderr);
        assert.match(proc.stdout, /overrides=palette\.accent,color\.textMuted,color\.textFaint/);
        const theme = JSON.parse(fs.readFileSync(path.join(dir, "themes", "catalog", "muted", "theme.json"), "utf8"));
        assert.equal(theme.tokens.color.textMuted, "mix({palette.foreground}, {palette.background}, 0.05)");
        assert.equal(theme.tokens.color.textFaint, "mix({palette.foreground}, {palette.background}, 0.11)");
        const mutedAmount = Number(/, (0\.\d+)\)/.exec(theme.tokens.color.textMuted)[1]);
        const faintAmount = Number(/, (0\.\d+)\)/.exec(theme.tokens.color.textFaint)[1]);
        assert.ok(mutedAmount < faintAmount, `muted=${mutedAmount} faint=${faintAmount}`);
        const contrast = spawnSync(NODE, [CONTRAST, path.join(dir, "themes")], { encoding: "utf8", env: env(dir) });
        assert.equal(contrast.status, 0, contrast.stdout + contrast.stderr);

        const copy = converterCopy(path.join(dir, "control"), "return Math.floor(faintAmount * (defaults.textMuted / defaults.textFaint) * 100) / 100;", "return defaults.textMuted;");
        const mutantDir = path.join(dir, "mutant");
        freshRoot(mutantDir);
        copyFixtureArchives(mutantDir);
        const mutant = runThemes(mutantDir, ["muted"], [], copy);
        assert.equal(mutant.status, 0, mutant.stdout + mutant.stderr);
        const mutantTheme = JSON.parse(fs.readFileSync(path.join(dir, "mutant", "themes", "catalog", "muted", "theme.json"), "utf8"));
        const mutantMuted = Number(/, (0\.\d+)\)/.exec(mutantTheme.tokens.color.textMuted)[1]);
        const mutantFaint = Number(/, (0\.\d+)\)/.exec(mutantTheme.tokens.color.textFaint)[1]);
        assert.ok(mutantMuted >= mutantFaint, `mutant kept hierarchy muted=${mutantMuted} faint=${mutantFaint}`);
    });

    row("fade default shape refusal names the token", dir => {
        freshRoot(dir);
        copyFixtureArchives(dir);
        const copy = converterCopy(dir, "const value = logic.nodeAt(tokens, token).value;", "const value = token === \"color.textFaint\" ? \"{palette.foreground}\" : logic.nodeAt(tokens, token).value;");
        const proc = runThemes(dir, ["beta"], [], copy);
        assert.equal(proc.status, 1, proc.stdout + proc.stderr);
        assert.match(proc.stderr, /convert-v1-themes: refused: token=color\.textFaint reason=fade-shape/);
    });

    row("preserves unselected catalog entries", dir => {
        assertPreservesUnselected(dir);
        const copy = converterCopy(path.join(dir, "control"), "for (const entry of existing.entries || []) byName.set(entry.name, entry);", "");
        let failed = false;
        try {
            assertPreservesUnselected(path.join(dir, "mutant"), copy);
        } catch (_) {
            failed = true;
        }
        assert.equal(failed, true, "mutant that drops existing entries preserved them");
    });


    row("held-back body text removes stale output", dir => {
        freshRoot(dir);
        fs.mkdirSync(path.join(dir, "themes", "catalog", "body"), { recursive: true });
        fs.mkdirSync(path.join(dir, "themes", "catalog", "thumbnails"), { recursive: true });
        fs.writeFileSync(path.join(dir, "themes", "catalog", "body", "theme.json"), "stale\n");
        fs.writeFileSync(path.join(dir, "themes", "catalog", "thumbnails", "body.jpg"), "stale\n");
        fs.writeFileSync(path.join(dir, "themes", "catalog", "index.json"), JSON.stringify({
            schemaVersion: 1,
            entries: [{ name: "body", mode: "dark", thumbnail: "thumbnails/body.jpg", palette: { background: "#888888", foreground: "#777777", accent: "#777777", success: "#777777", warning: "#777777", danger: "#777777", info: "#777777" }, imagery: null }]
        }, null, 2) + "\n");
        const proc = runThemes(dir, ["body"]);
        assert.equal(proc.status, 0, proc.stdout + proc.stderr);
        assert.match(proc.stdout, /held-back theme=body text=color\.text surface=color\.background ratio=1\.26 floor=4\.5/);
        assert.equal(fs.existsSync(path.join(dir, "themes", "catalog", "body")), false, "stale package remains");
        assert.equal(fs.existsSync(path.join(dir, "themes", "catalog", "thumbnails", "body.jpg")), false, "stale thumbnail remains");
        const index = JSON.parse(fs.readFileSync(path.join(dir, "themes", "catalog", "index.json"), "utf8"));
        assert.deepEqual(index.entries, []);
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
        ["unsafe archive hard link", rootDir => replaceArchive(rootDir, "alpha", [{ name: "backgrounds/link.jpg", type: "1", link: "../x" }]), "theme=alpha key=archive.member"],
        ["unsupported archive member type", rootDir => replaceArchive(rootDir, "alpha", [{ name: "backgrounds/device.jpg", type: "3" }]), "theme=alpha key=archive.member"],
        ["bad archive checksum", rootDir => replaceArchive(rootDir, "alpha", [{ name: "backgrounds/a.jpg", data: sampleImage(), badChecksum: true }]), "theme=alpha key=archive.header reason=checksum"],
        ["bad archive size field", rootDir => replaceArchive(rootDir, "alpha", [{ name: "backgrounds/a.jpg", data: sampleImage(), sizeField: "not-octal" }]), "theme=alpha key=archive.header reason=size"],
        ["global pax path refused", rootDir => replaceArchive(rootDir, "alpha", [{ name: "pax", type: "g", data: paxRecord("path", "backgrounds/a.jpg") }, { name: "backgrounds/a.jpg", data: sampleImage() }]), "theme=alpha key=archive.header reason=global-pax-path"],
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

    row("pax path background name is used", dir => {
        freshRoot(dir);
        copyFixtureArchives(dir);
        replaceArchive(dir, "alpha", [
            { name: "pax", type: "x", data: paxRecord("path", "backgrounds/00-pax-name.jpg") },
            { name: "backgrounds/zz-raw.jpg", data: sampleImage() }
        ]);
        const proc = runThemes(dir, ["alpha"]);
        assert.equal(proc.status, 0, proc.stdout + proc.stderr);
        assert.match(proc.stdout, /source=00-pax-name\.jpg/);
    });

    row("gnu long background name is used", dir => {
        freshRoot(dir);
        copyFixtureArchives(dir);
        const long = "backgrounds/00-gnu-long-name-" + "x".repeat(100) + ".jpg";
        replaceArchive(dir, "alpha", [
            { name: "././@LongLink", type: "L", data: long + "\0" },
            { name: "backgrounds/zz-raw.jpg", data: sampleImage() }
        ]);
        const proc = runThemes(dir, ["alpha"]);
        assert.equal(proc.status, 0, proc.stdout + proc.stderr);
        assert.ok(proc.stdout.includes(`source=${path.basename(long)}`), proc.stdout);
    });

    row("global pax without path is accepted", dir => {
        freshRoot(dir);
        copyFixtureArchives(dir);
        replaceArchive(dir, "alpha", [
            { name: "pax", type: "g", data: paxRecord("comment", "fixture") },
            { name: "backgrounds/a.jpg", data: sampleImage() }
        ]);
        const proc = runThemes(dir, ["alpha"]);
        assert.equal(proc.status, 0, proc.stdout + proc.stderr);
        assert.match(proc.stdout, /source=a\.jpg/);
    });

    row("nested backgrounds members are skipped", dir => {
        freshRoot(dir);
        copyFixtureArchives(dir);
        replaceArchive(dir, "alpha", [
            { name: "backgrounds/0-sub/a.jpg", data: sampleImage() },
            { name: "backgrounds/z-direct.jpg", data: sampleImage() }
        ]);
        const proc = runThemes(dir, ["alpha"]);
        assert.equal(proc.status, 0, proc.stdout + proc.stderr);
        assert.match(proc.stdout, /source=z-direct\.jpg/);
        const copy = converterCopy(path.join(dir, "control"),
            'return fileName.includes("/") ? null : collect(entries, fileName);',
            'return collect(entries, path.basename(fileName));');
        const mutant = runThemes(dir, ["alpha"], [], copy);
        assert.equal(mutant.status, 0, mutant.stdout + mutant.stderr);
        assert.doesNotMatch(mutant.stdout, /source=z-direct\.jpg/, "mutant still skipped nested member");
    });

    row("a conversion while the download lock is held is refused busy", dir => {
        freshRoot(dir);
        copyFixtureArchives(dir);
        const cache = path.join(dir, "cache");
        const lockFile = path.join(cache, "download.lock");
        fs.mkdirSync(cache, { recursive: true });
        // flock(1) locks this process's descriptor, which it inherits as
        // fd 3; the lock stays held here until the descriptor is closed.
        const held = fs.openSync(lockFile, "a");
        try {
            const taken = spawnSync(FLOCK, ["-n", "3"], { stdio: ["ignore", "ignore", "inherit", held] });
            assert.equal(taken.status, 0, "the suite takes the download lock");
            const proc = runThemes(dir, ["alpha"]);
            assert.equal(proc.status, 1, proc.stdout + proc.stderr);
            assert.equal(proc.stderr.split("\n")[0], `convert-v1-themes: refused: asset-busy path=${lockFile}`);
            assert.deepEqual(fs.readdirSync(cache), ["download.lock"], "a busy conversion touches no part");
            const copy = converterCopy(path.join(dir, "control"), "        lock = download.holdDownloadLock(args.assetCache);\n", "");
            const mutant = runThemes(dir, ["alpha"], [], copy);
            assert.equal(mutant.status, 0, "the lockless mutant converts under the held lock: " + mutant.stdout + mutant.stderr);
        } finally {
            fs.closeSync(held);
        }
    });

    row("https redirect to http is refused", dir => {
        freshRoot(dir);
        copyFixtureArchives(dir);
        const server = startRedirectServer(dir);
        try {
            const port = waitForPort(server);
            const proc = runThemes(dir, ["alpha"], ["--asset-base", `https://127.0.0.1:${port}`], CONVERTER, { NODE_TLS_REJECT_UNAUTHORIZED: "0" });
            assert.equal(proc.status, 1, proc.stdout + proc.stderr);
            assert.ok(proc.stderr.includes("asset-download reason=redirect-not-https"), proc.stderr);
        } finally {
            server.child.kill();
        }
    });

    row("terminal overlay control", dir => assertMutantFails(dir, "terminal overlay", "slots[slot] = terminalOverrides[slot] || colors[slot];", "slots[slot] = colors[slot];"));
    row("first image control", dir => assertMutantFails(dir, "first image", "const first = backgrounds.firstImageName(entries);", "const first = entries.map(entry => entry.name).sort().pop() || null;"));
    row("deterministic index control", dir => assertMutantFails(dir, "deterministic index", "entries: Array.from(byName.values()).sort((a, b) => codeUnitCompare(a.name, b.name))", "entries: Array.from(byName.values())"));
    row("override only on failure control", dir => assertMutantFails(dir, "override only on failure", "if (roleShortfall(initialShortfalls, \"textFaint\") !== undefined) {", "if (true) {"));
    row("largest textFaint control", dir => assertMutantFails(dir, "largest textFaint", "for (let step = start; step >= 0; step--)", "for (let step = 0; step <= start; step++)"));
    row("smallest status control", dir => assertMutantFails(dir, "smallest status", "for (const role of STATUS_ROLES) {\n        const pathName = `color.${role}`;\n        if (initialShortfalls.find(shortfall => shortfall.text === pathName) === undefined) continue;\n        let chosen = null;\n        for (let step = 1; step <= 100; step++)", "for (const role of STATUS_ROLES) {\n        const pathName = `color.${role}`;\n        if (initialShortfalls.find(shortfall => shortfall.text === pathName) === undefined) continue;\n        let chosen = null;\n        for (let step = 100; step >= 1; step--)"));
    row("unfixable hold-back control", dir => {
        freshRoot(dir);
        const copy = converterCopy(dir, "if (firstUnfixable !== undefined) return { held: true, shortfall: firstUnfixable };", "if (false) return { held: true, shortfall: firstUnfixable };");
        const proc = runThemes(dir, ["body"], [], copy);
        assert.equal(proc.status, 0, proc.stdout + proc.stderr);
        assert.match(proc.stdout, /held-back theme=body/, "mutant stopped holding the theme back before reporting a reason");
        assert.doesNotMatch(proc.stdout, /text=color\.text surface=color\.background/, "mutant still reported the unfixable role first");
    });
    row("held-back removal control", dir => {
        freshRoot(dir);
        const copy = converterCopy(dir, "fs.rmSync(path.join(catalogDir, item.theme), { recursive: true, force: true });", "");
        fs.mkdirSync(path.join(dir, "themes", "catalog", "body"), { recursive: true });
        fs.writeFileSync(path.join(dir, "themes", "catalog", "body", "theme.json"), "stale\n");
        const proc = runThemes(dir, ["body"], [], copy);
        assert.equal(proc.status, 0, proc.stdout + proc.stderr);
        assert.equal(fs.existsSync(path.join(dir, "themes", "catalog", "body")), true, "mutant removed stale package");
    });
} finally {
    rmTree(root);
}

if (failures > 0) process.exit(1);
console.log("test-convert-v1-themes: ok");
