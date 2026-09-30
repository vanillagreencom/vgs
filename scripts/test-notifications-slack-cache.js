#!/usr/bin/env node
// The one reader of Slack's disk cache, shell/plugins/vgs.notifications/
// slack-cache.js, through both of its callers: the workspace icons, its own
// `copy` verb as WorkspaceIcons.qml runs it, and the custom emoji,
// slack-emoji.js, run through slack-photos.js as SlackPhotos.qml runs it,
// with no token and a stub ImageMagick that copies each image it is handed
// and logs its size. The cache is a copy of the smoke fixture,
// scripts/smoke/fixtures/slack, whose two entries were named for their URLs
// with Python's hashlib as Chromium names an entry, the derivation that
// named the entries of Slack 4.52.162's own cache on 2026-09-28, beside
// planted entries this file writes.
//
// The controls at the end edit a copy of the reader, one rule at a time,
// and require the caller or callers that rule serves to fail on the copy:
// every format rule and the bound turn both callers red. The listing's cap
// of 262,144 entries is not exercised: reaching it takes that many files.
// Its URL prefix is not observable through a caller, since slack-emoji.js
// matches every URL it is handed against its own rule.
"use strict";

const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const repo = path.join(__dirname, "..");
const pluginDir = path.join(repo, "shell", "plugins", "vgs.notifications");
const fixture = path.join(repo, "scripts", "smoke", "fixtures", "slack", "Cache", "Cache_Data");
const scratch = path.join(repo, "tmp", "test-notifications-slack-cache-" + process.pid);

const ICON_URL = "https://avatars.slack-edge.com/fixture/acme_88.png";
// The fixture icon's body: 370 bytes of PNG, whose SHA-256 opens with this.
const ICON_VERSION = "0b21e82d04b41988";
const EMOJI_TEAM = "T0ACME";
// The fixture emoji's body: 656 bytes of PNG, whose SHA-256 opens with this.
const EMOJI_SIZE = 656;
const EMOJI_HEX = "9328bc7b74980216";
const ICON_MAX = 5 * 1024 * 1024;
const EMOJI_MAX = 256 * 1024;
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const END = Buffer.from([0xd8, 0x41, 0x0d, 0x97, 0x45, 0x6f, 0xfa, 0xf4]);

// The file name Chromium gives `url`'s entry.
function entryName(url) {
    return Buffer.from(crypto.createHash("sha1").update("1/0/" + url).digest().subarray(0, 8)).reverse().toString("hex") + "_0";
}

// One simple-cache entry's bytes: the header, the key, the body, the end
// record, then a headers stream and its end record, as Slack writes them.
function entryBytes(key, body, ended) {
    const header = Buffer.alloc(24);
    header.writeUInt32LE(0xa7725c30, 0);
    header.writeUInt32LE(0xfcfb6d1b, 4);
    header.writeUInt32LE(5, 8);
    header.writeUInt32LE(Buffer.byteLength(key), 12);
    const trailer = Buffer.concat([END, Buffer.alloc(12)]);
    return Buffer.concat([header, Buffer.from(key), body].concat(ended ? [trailer, Buffer.from("HTTP/1.1 200\0"), trailer] : []));
}

function plant(dir, url, body, options) {
    const opts = options || {};
    const key = opts.key !== undefined ? opts.key : "1/0/" + url;
    fs.writeFileSync(path.join(dir, opts.name || entryName(url)), entryBytes(key, body, opts.ended !== false));
}

function png(size) {
    return Buffer.concat([PNG, Buffer.alloc(size - PNG.length, 7)]);
}

function version(bytes) {
    return crypto.createHash("sha256").update(bytes).digest("hex").slice(0, 16);
}

// The shared world: an icon cache and an emoji cache, each a copy of the
// fixture beside planted entries, and a directory outside both that a
// link points into.
const world = {};
function build() {
    const elsewhere = path.join(scratch, "elsewhere");
    fs.mkdirSync(elsewhere, { recursive: true });

    const icons = path.join(scratch, "icon-cache");
    fs.cpSync(fixture, icons, { recursive: true });
    const edge = png(ICON_MAX);
    const url = name => "https://avatars.slack-edge.com/fixture/" + name + ".png";
    plant(icons, url("wrong-key"), png(64), { key: "1/0/" + url("wrong-kez") });
    plant(icons, url("unended"), png(64), { ended: false });
    plant(icons, url("empty"), Buffer.alloc(0));
    plant(icons, url("edge"), edge);
    plant(icons, url("huge"), png(ICON_MAX + 1));
    plant(elsewhere, url("linked"), png(64), { name: "icon-target" });
    fs.symlinkSync(path.join(elsewhere, "icon-target"), path.join(icons, entryName(url("linked"))));
    assert.equal(childProcess.spawnSync("mkfifo", [path.join(icons, entryName(url("fifo")))]).status, 0, "the FIFO fixture is made");
    world.icons = { dir: icons, url, edgeVersion: version(edge) };

    const emoji = path.join(scratch, "emoji-cache");
    fs.cpSync(fixture, emoji, { recursive: true });
    const emojiUrl = name => `https://emoji.slack-edge.com/${EMOJI_TEAM}/${name}/00000000000000aa.png`;
    plant(emoji, emojiUrl("oversized"), png(EMOJI_MAX + 1));
    plant(emoji, emojiUrl("unended"), png(64), { ended: false });
    plant(emoji, emojiUrl("misnamed"), png(64), { name: "00000000000000aa_0" });
    plant(elsewhere, emojiUrl("linked"), png(64), { name: "emoji-target" });
    fs.symlinkSync(path.join(elsewhere, "emoji-target"), path.join(emoji, entryName(emojiUrl("linked"))));
    world.emoji = { dir: emoji };

    // The stub ImageMagick: each `<coder>:<input>[0]` is copied to the
    // `PNG32:<output>` after it, and its size logged.
    const bin = path.join(scratch, "bin");
    fs.mkdirSync(bin, { recursive: true });
    fs.writeFileSync(path.join(bin, "magick"), `#!${process.execPath}
const fs = require("node:fs");
const args = process.argv.slice(2);
let input = "";
for (let i = 0; i < args.length; i++) {
    const source = /^(?:png|gif|jpeg):(.+)\\[0\\]$/.exec(args[i]);
    if (source !== null) input = source[1];
    if (args[i] === "-write") {
        fs.appendFileSync(process.env.STUB_MAGICK_LOG, fs.statSync(input).size + "\\n");
        fs.copyFileSync(input, args[i + 1].replace(/^PNG32:/, ""));
    }
}
`, { mode: 0o700 });
    world.bin = bin;
}

// Each caller answers the rules it breaks, [] when it keeps them all.
function iconCaller(dir, run) {
    const broken = [];
    const expect = (label, want, got) => {
        try {
            assert.deepEqual(got, want);
        } catch (_e) {
            broken.push(label + ": want " + JSON.stringify(want) + " got " + JSON.stringify(got));
        }
    };
    const out = path.join(scratch, "icons-" + run);
    fs.mkdirSync(out, { recursive: true });
    fs.writeFileSync(path.join(out, "T0GONE-0"), "stale");
    const copy = args => {
        const result = childProcess.spawnSync(process.execPath, [path.join(dir, "slack-cache.js")].concat(args), { env: {}, encoding: "utf8", timeout: 30000 });
        return { status: result.status, stdout: result.stdout, stderr: result.stderr };
    };
    const { dir: cache, url, edgeVersion } = world.icons;
    const names = ["acme", "absent", "wrong-key", "unended", "empty", "edge", "huge", "linked", "fifo"];
    const args = ["copy", cache, out];
    names.forEach((name, n) => args.push(out + "/" + name, name === "acme" ? ICON_URL : url(name)));
    const got = copy(args);
    expect("each URL answers one line", {
        status: 0,
        stdout: [
            `copied ${out}/acme version=${ICON_VERSION}`,
            `skipped ${out}/absent reason=missing`,
            `skipped ${out}/wrong-key reason=malformed`,
            `skipped ${out}/unended reason=malformed`,
            `skipped ${out}/empty reason=malformed`,
            `copied ${out}/edge version=${edgeVersion}`,
            `skipped ${out}/huge reason=too-large`,
            `skipped ${out}/linked reason=unreadable`,
            `skipped ${out}/fifo reason=unreadable`
        ].join("\n") + "\n",
        stderr: ""
    }, got);
    const read = name => { try { return fs.readFileSync(path.join(out, name)); } catch (_e) { return Buffer.alloc(0); } };
    expect("the copy is the body alone, a PNG", [370, PNG.toString("hex")], [read("acme").length, read("acme").subarray(0, 8).toString("hex")]);
    expect("a body at the bound is copied whole", ICON_MAX, read("edge").length);
    expect("the out directory holds only this run's copies", ["acme", "edge"], fs.readdirSync(out).sort());
    fs.writeFileSync(path.join(out, "acme"), "kept");
    expect("a copy outside the out directory is refused before anything is removed",
        { status: 3, stdout: "", stderr: `notifications-slack-cache: refused: outside=${scratch}/x dir=${out}\n`, kept: "kept" },
        Object.assign(copy(["copy", cache, out, out + "/acme", ICON_URL, scratch + "/x", ICON_URL]), { kept: read("acme").toString() }));
    expect("a copy climbing out of the out directory is refused",
        { status: 3, stdout: "", stderr: `notifications-slack-cache: refused: outside=${out}/.. dir=${out}\n` },
        copy(["copy", cache, out, out + "/..", ICON_URL]));
    const usage = { status: 2, stdout: "", stderr: "notifications-slack-cache: refused: usage\n" };
    expect("an odd number of copy arguments is refused", usage, copy(["copy", cache, out, out + "/acme"]));
    expect("an unknown verb is refused", usage, copy(["move", cache, out]));
    expect("no arguments are refused", usage, copy([]));
    return broken;
}

function emojiCaller(dir, run) {
    const broken = [];
    const root = path.join(scratch, "emoji-" + run);
    const log = path.join(scratch, "magick-" + run + ".log");
    const result = childProcess.spawnSync(process.execPath, [path.join(dir, "slack-photos.js"), "refresh", root, "--emoji", world.emoji.dir, EMOJI_TEAM], {
        env: {
            PATH: world.bin,
            HOME: scratch,
            STUB_MAGICK_LOG: log,
            VGS_NOTIFICATIONS_SLACK_TEST: "1",
            VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR: world.bin
        },
        encoding: "utf8",
        timeout: 60000
    });
    let emoji = null;
    try {
        emoji = JSON.parse(result.stdout).emoji;
    } catch (_e) {
        broken.push("the helper printed no JSON line: status=" + result.status + " stderr=" + result.stderr);
        return broken;
    }
    const sizes = fs.existsSync(log) ? fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map(Number) : [];
    const checks = [
        ["the cached emoji is the fixture's body and nothing else is", [{ team: EMOJI_TEAM, map: { "smoke-party": EMOJI_HEX }, count: 1, pending: 0 }], emoji],
        ["the oversized and the unended entries fail, each counted", "notifications-slack-photos: emoji images=failed count=2\n", result.stderr],
        ["the converter is handed the fixture's body alone, never a source past the bound", [EMOJI_SIZE], sizes]
    ];
    for (const [label, want, got] of checks) {
        try {
            assert.deepEqual(got, want);
        } catch (_e) {
            broken.push(label + ": want " + JSON.stringify(want) + " got " + JSON.stringify(got));
        }
    }
    return broken;
}

function main() {
    build();
    const icon = iconCaller(pluginDir, "real");
    const emoji = emojiCaller(pluginDir, "real");
    for (const line of icon.concat(emoji)) console.error("  FAIL  " + line);
    assert.equal(icon.length + emoji.length, 0, "the reader keeps every rule through both callers");

    const reader = fs.readFileSync(path.join(pluginDir, "slack-cache.js"), "utf8");
    const lines = /^each URL answers one line/;
    const emojiMap = /^the cached emoji is the fixture's body/;
    // label | text in slack-cache.js | its replacement | the check each
    // caller it turns red must fail
    const table = [
        ["hash read little-endian", ".reverse().toString(\"hex\")", ".toString(\"hex\")", { icon: lines, emoji: emojiMap }],
        ["key length at bytes 12-15", "const KEY_LENGTH_AT = 12;", "const KEY_LENGTH_AT = 8;", { icon: lines, emoji: emojiMap }],
        ["key prefix", "const KEY_PREFIX = \"1/0/\";", "const KEY_PREFIX = \"1/1/\";", { icon: lines, emoji: emojiMap }],
        ["end record", "0x45, 0x6f, 0xfa, 0xf4]", "0x45, 0x6f, 0xfa, 0xf5]", { icon: lines, emoji: emojiMap }],
        ["body bound", "Math.min(size, start + max + END_RECORD.length)", "size", { icon: lines, emoji: /^the converter is handed the fixture's body alone/ }],
        ["no link followed", " | fs.constants.O_NOFOLLOW", "", { icon: lines, emoji: emojiMap }],
        ["regular files only", "if (fs.fstatSync(fd).isFile()) return { fd };", "return { fd };", { icon: lines }],
        ["entry keyed to its URL", " || !bytes.subarray(HEADER_BYTES, start).equals(key)", "", { icon: lines }],
        ["empty body is malformed", "if (end === start) return { ok: false, reason: \"malformed\" };", "", { icon: lines }],
        ["listed entry named by its key", "if (entryName(url) !== name) continue;", "", { emoji: /^the oversized and the unended entries fail/ }],
        ["out directory emptied", "fs.rmSync(file, { force: true });", "", { icon: /^the out directory holds only this run's copies/ }],
        ["copy version", "\" version=\" + version", "\"\"", { icon: lines }],
        ["copy inside the out directory", "if (to !== dir + \"/\" + name || name === \"\" || name === \".\" || name === \"..\")", "if (name === \"\")", { icon: /^a copy outside the out directory is refused/ }],
        ["paired copy arguments", "if (args.length < 2 || args.length % 2 !== 0)", "if (args.length < 2)", { icon: /^an odd number of copy arguments is refused/ }]
    ];
    let passed = 0;
    table.forEach(([label, needle, replacement, want], index) => {
        assert.equal(reader.split(needle).length, 2, `control "${label}": the text to replace must occur once`);
        const mutated = reader.replace(needle, () => replacement);
        assert.notEqual(mutated, reader, `control "${label}": the copy must change`);
        const copyDir = path.join(scratch, "controls", String(index));
        fs.mkdirSync(copyDir, { recursive: true });
        fs.writeFileSync(path.join(copyDir, "slack-cache.js"), mutated);
        assert.equal(childProcess.spawnSync(process.execPath, ["--check", path.join(copyDir, "slack-cache.js")]).status, 0, `control "${label}": the copy must stay valid JavaScript`);
        for (const name of ["slack-emoji.js", "slack-photos.js"]) fs.copyFileSync(path.join(pluginDir, name), path.join(copyDir, name));
        const callers = { icon: iconCaller, emoji: emojiCaller };
        for (const [caller, failure] of Object.entries(want)) {
            const broken = callers[caller](copyDir, "control-" + index);
            assert.ok(broken.length > 0, `control "${label}": the ${caller} caller passed on a reader without that rule`);
            assert.ok(broken.some(line => failure.test(line)), `control "${label}": the ${caller} caller failed for another reason: ${broken.join("; ")}`);
        }
        passed++;
    });
    return passed;
}

fs.rmSync(scratch, { recursive: true, force: true });
fs.mkdirSync(scratch, { recursive: true });
try {
    const controls = main();
    fs.rmSync(scratch, { recursive: true, force: true });
    console.log("test-notifications-slack-cache: ok controls=" + controls);
} catch (error) {
    fs.rmSync(scratch, { recursive: true, force: true });
    console.error(error && error.stack ? error.stack : String(error));
    process.exit(1);
}
