#!/usr/bin/env node
// The verified fetch and the tar reader, bin/lib/theme-download.js, which
// `vgsh theme wallpapers` and tools/convert-v1-themes share. Every expected
// value below was written by hand, never read from the library. The fetch
// rows read file:// fixtures; the HTTPS transport's redirect rule is
// reached through the converter in scripts/test-convert-v1-themes.js, and
// no row here reaches the network.
//
// The controls at the end edit a copy of the library, one rule at a time,
// and require this suite to fail on each copy.
"use strict";
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const zlib = require("node:zlib");
const { paxRecord, tarBytes } = require("./tar-fixture.js");

const libFile = path.join(__dirname, "..", "bin", "lib", "theme-download.js");
const temp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "theme-download-")));
const PIN = { repo: "https://github.com/vanillagreencom/vgs-themes", release: "themes-v1", archive: "vgs-theme-moor-r1.tar.gz" };
const LONG = "backgrounds/" + "l".repeat(120) + ".png";

// archiveUrl rows: the base, whether file:// is allowed, and the URL, or
// null for the `not-https` refusal.
const URLS = [
    [undefined, false, "https://github.com/vanillagreencom/vgs-themes/releases/download/themes-v1/vgs-theme-moor-r1.tar.gz"],
    ["", false, "https://github.com/vanillagreencom/vgs-themes/releases/download/themes-v1/vgs-theme-moor-r1.tar.gz"],
    ["https://mirror.example/assets//", false, "https://mirror.example/assets/themes-v1/vgs-theme-moor-r1.tar.gz"],
    ["http://mirror.example/assets", false, null],
    ["http://mirror.example/assets", true, null],
    ["file:///srv/assets", false, null],
    ["file:///srv/assets", true, "file:///srv/assets/themes-v1/vgs-theme-moor-r1.tar.gz"],
    ["not a url", true, null]
];

// cacheDir rows: the environment and the directory.
const CACHES = [
    [{ XDG_CACHE_HOME: "/x/cache", HOME: "/h" }, "/x/cache/vgs/theme-assets"],
    [{ XDG_CACHE_HOME: "", HOME: "/h" }, "/h/.cache/vgs/theme-assets"],
    [{ HOME: "/h" }, "/h/.cache/vgs/theme-assets"]
];

const file = (name, data, extra = {}) => Object.assign({ name, data }, extra);
const member = (name, type, kind, body) => ({ name, type, kind, size: Buffer.byteLength(body), body });

// TarReader rows: the tar bytes and the members the policy sees with the
// body each sink was handed, or the refusal `{ step, reason, member }`.
const TARS = [
    ["a regular file", tarBytes([file("backgrounds/a.png", "abc")]), [member("backgrounds/a.png", "0", "file", "abc")]],
    ["a body past one block", tarBytes([file("backgrounds/a.png", "x".repeat(1300)), file("backgrounds/b.png", "y")]),
        [member("backgrounds/a.png", "0", "file", "x".repeat(1300)), member("backgrounds/b.png", "0", "file", "y")]],
    ["an empty member", tarBytes([file("backgrounds/e.png", "")]), [member("backgrounds/e.png", "0", "file", "")]],
    ["a NUL typeflag is a regular file", tarBytes([file("backgrounds/a.png", "abc", { type: "\0" })]), [member("backgrounds/a.png", "", "file", "abc")]],
    ["each leading ./ is dropped", tarBytes([file("././backgrounds/a.png", "abc")]), [member("backgrounds/a.png", "0", "file", "abc")]],
    ["a directory's trailing slash is dropped", tarBytes([file("backgrounds/", "", { type: "5" })]), [member("backgrounds", "5", "directory", "")]],
    ["the kinds", tarBytes([file("s", "", { type: "2", link: "t" }), file("h", "", { type: "1", link: "t" }), file("f", "", { type: "6" })]),
        [member("s", "2", "symlink", ""), member("h", "1", "hardlink", ""), member("f", "6", "other", "")]],
    ["a pax path names the next member", tarBytes([file("pax", paxRecord("path", "backgrounds/from-pax.png"), { type: "x" }), file("backgrounds/raw.png", "abc"), file("backgrounds/next.png", "d")]),
        [member("backgrounds/from-pax.png", "0", "file", "abc"), member("backgrounds/next.png", "0", "file", "d")]],
    ["a GNU long name names the next member", tarBytes([file("././@LongLink", LONG + "\0", { type: "L" }), file("backgrounds/raw.png", "abc")]),
        [member(LONG, "0", "file", "abc")]],
    ["a ustar prefix leads the name", tarBytes([file("a.png", "abc", { prefix: "backgrounds" })]), [member("backgrounds/a.png", "0", "file", "abc")]],
    ["a global pax header without a path is read past", tarBytes([file("g", paxRecord("comment", "fixture"), { type: "g" }), file("backgrounds/a.png", "abc")]),
        [member("backgrounds/a.png", "0", "file", "abc")]],
    ["reading stops at the first zero block", Buffer.concat([tarBytes([file("backgrounds/a.png", "abc")]), Buffer.from("trailing junk")]),
        [member("backgrounds/a.png", "0", "file", "abc")]],
    ["a global pax path is refused", tarBytes([file("g", paxRecord("path", "backgrounds/a.png"), { type: "g" }), file("backgrounds/a.png", "abc")]),
        { step: "header", reason: "global-pax-path", member: null }],
    ["a pax size is refused", tarBytes([file("pax", paxRecord("size", "3"), { type: "x" }), file("backgrounds/a.png", "abc")]),
        { step: "header", reason: "pax-size", member: null }],
    ["a pax record with no length is refused", tarBytes([file("pax", "garbage", { type: "x" })]), { step: "header", reason: "pax", member: null }],
    ["a pax record past its header is refused", tarBytes([file("pax", "9 a=b\n", { type: "x" })]), { step: "header", reason: "pax-length", member: null }],
    ["a pax record with no key is refused", tarBytes([file("pax", "5 ab\n", { type: "x" })]), { step: "header", reason: "pax-record", member: null }],
    ["a bad checksum is refused", tarBytes([file("backgrounds/a.png", "abc", { badChecksum: true })]), { step: "header", reason: "checksum", member: null }],
    ["a size that is no octal is refused", tarBytes([file("backgrounds/a.png", "abc", { sizeField: "not-octal" })]), { step: "header", reason: "size", member: null }],
    ["a base-256 size is refused", tarBytes([file("backgrounds/a.png", "abc", { sizeField: Buffer.from([0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3]) })]),
        { step: "header", reason: "size", member: null }],
    ["an absolute name is refused", tarBytes([file("/etc/passwd", "abc")]), { step: "name", reason: "path", member: "/etc/passwd" }],
    ["a .. segment is refused", tarBytes([file("backgrounds/../../x.png", "abc")]), { step: "name", reason: "path", member: "backgrounds/../../x.png" }],
    ["a pax path with a .. segment is refused", tarBytes([file("pax", paxRecord("path", "../x.png"), { type: "x" }), file("backgrounds/a.png", "abc")]),
        { step: "name", reason: "path", member: "../x.png" }],
    ["an empty segment is refused", tarBytes([file("backgrounds//a.png", "abc")]), { step: "name", reason: "path", member: "backgrounds//a.png" }],
    ["a . member is refused", tarBytes([file(".", "", { type: "5" })]), { step: "name", reason: "path", member: "." }],
    ["a body the stream cuts short is refused", tarBytes([file("backgrounds/a.png", "x".repeat(1300))]).subarray(0, 1000),
        { step: "header", reason: "truncated", member: null }],
    ["a header the stream cuts short is refused", tarBytes([file("backgrounds/a.png", "abc")]).subarray(0, 300),
        { step: "header", reason: "truncated", member: null }],
    ["a long name with no member after it is refused", tarBytes([file("././@LongLink", LONG + "\0", { type: "L" })]).subarray(0, 1024),
        { step: "header", reason: "long-name", member: null }]
];

// Each chunking a stream may hand the reader: the whole, single bytes, and
// chunks that end inside every header.
const CHUNKINGS = [Infinity, 1, 509];

// Push BYTES through a TarReader in chunks of SIZE: the members with their
// bodies, and whether every sink was closed.
function readTar(lib, bytes, size) {
    const seen = [];
    let open = 0;
    const reader = new lib.TarReader(m => {
        const row = { name: m.name, type: m.type, kind: m.kind, size: m.size, body: "" };
        seen.push(row);
        open += 1;
        return { write(chunk) { row.body += chunk.toString("latin1"); }, close() { open -= 1; } };
    });
    for (let at = 0; at < bytes.length; at += size) reader.push(bytes.subarray(at, Math.min(bytes.length, at + size)));
    reader.end();
    assert.equal(open, 0, "every sink is closed");
    return seen;
}

function refusalOf(e) {
    return { step: e.step, reason: e.reason, member: e.member };
}

async function refused(lib, run) {
    try {
        await run();
    } catch (e) {
        if (!(e instanceof lib.AssetRefusal)) throw e;
        return e;
    }
    assert.fail("no refusal");
}

const fileUrl = at => "file://" + at.split(path.sep).map(encodeURIComponent).join("/");
const sha256 = bytes => crypto.createHash("sha256").update(bytes).digest("hex");
const listing = dir => (fs.existsSync(dir) ? fs.readdirSync(dir).sort() : []);

// A fetch of SOURCE into a fresh cache under PIN's size and sha256: the
// answer, or the refusal, with the progress calls it made.
async function fetchInto(lib, dir, source, pin, keep) {
    const progress = [];
    const run = () => lib.fetchArchive(Object.assign({}, PIN, pin), fileUrl(source), dir, keep, (state, bytes) => progress.push([state, bytes]));
    try {
        return { answer: await run(), progress };
    } catch (e) {
        if (!(e instanceof lib.AssetRefusal)) throw e;
        return { refusal: e, progress };
    }
}

async function verify(lib, work) {
    assert.equal(lib.MEMBER_CEILING, 134217728);
    for (const [base, allowFile, want] of URLS) {
        const label = JSON.stringify([base, allowFile]);
        if (want !== null) {
            assert.equal(lib.archiveUrl(PIN, base, allowFile), want, label);
            continue;
        }
        let e = null;
        try {
            lib.archiveUrl(PIN, base, allowFile);
        } catch (caught) {
            e = caught;
        }
        assert.ok(e instanceof lib.AssetRefusal, label);
        assert.deepEqual([e.step, e.reason], ["fetch", "not-https"], label);
    }
    for (const [env, want] of CACHES) assert.equal(lib.cacheDir(env), want, JSON.stringify(env));

    for (const [label, bytes, want] of TARS) {
        for (const size of CHUNKINGS) {
            const at = label + " in chunks of " + size;
            if (Array.isArray(want)) {
                assert.deepEqual(readTar(lib, bytes, size), want, at);
                continue;
            }
            let e = null;
            try {
                readTar(lib, bytes, size);
            } catch (caught) {
                e = caught;
            }
            assert.ok(e instanceof lib.AssetRefusal, at + ": " + e);
            assert.deepEqual(refusalOf(e), want, at);
        }
    }
    const planted = new Error("policy");
    assert.throws(() => new lib.TarReader(() => { throw planted; }).push(tarBytes([file("a", "b")])), e => e === planted, "a policy's refusal passes through");

    // readArchive over a gzip file.
    const gz = path.join(work, "a.tar.gz");
    const body = crypto.randomBytes(200000);
    fs.writeFileSync(gz, zlib.gzipSync(tarBytes([file("backgrounds/a.png", body), file("backgrounds/b.png", "b")])));
    const unpacked = [];
    const progress = [];
    await lib.readArchive(gz, m => {
        const chunks = [];
        return { write(chunk) { chunks.push(Buffer.from(chunk)); }, close() { unpacked.push([m.name, Buffer.concat(chunks)]); } };
    }, (state, bytes) => progress.push([state, bytes]));
    assert.deepEqual(unpacked, [["backgrounds/a.png", body], ["backgrounds/b.png", Buffer.from("b")]], "readArchive hands each body whole");
    assert.deepEqual(progress[0], ["unpacking", 0]);
    assert.deepEqual(progress[progress.length - 1], ["unpacking", fs.statSync(gz).size]);
    let closed = 0;
    fs.writeFileSync(gz, zlib.gzipSync(tarBytes([file("backgrounds/a.png", body)]).subarray(0, 100000)));
    let e = await refused(lib, () => lib.readArchive(gz, () => ({ write() {}, close() { closed += 1; } }), () => {}));
    assert.deepEqual([e.step, e.reason, closed], ["header", "truncated", 1], "a failed read closes the open sink");
    fs.writeFileSync(gz, "no gzip");
    e = await refused(lib, () => lib.readArchive(gz, () => null, () => {}));
    assert.deepEqual([e.step, e.reason, e.detail], ["archive", "gzip", "error=Z_DATA_ERROR"]);
    e = await refused(lib, () => lib.readArchive(path.join(work, "absent.tar.gz"), () => null, () => {}));
    assert.deepEqual([e.step, e.reason, e.detail], ["archive", "unreadable", "path=" + path.join(work, "absent.tar.gz") + " error=ENOENT"]);

    // fetchArchive from file:// sources.
    const archive = path.join(work, "archive.tar.gz");
    const bytes = crypto.randomBytes(300000);
    fs.writeFileSync(archive, bytes);
    const size = bytes.length;
    const sha = sha256(bytes);
    const part = sha + ".tar.gz.part";
    let dir = path.join(work, "cache-part");
    let got = await fetchInto(lib, dir, archive, { size, sha256: sha }, false);
    assert.deepEqual(got.answer, { file: path.join(dir, part), cached: false }, "without keep the part is the answer");
    assert.deepEqual(fs.readFileSync(got.answer.file), bytes);
    assert.deepEqual(got.progress[0], ["downloading", 0]);
    assert.deepEqual(got.progress[got.progress.length - 2], ["downloading", size]);
    assert.deepEqual(got.progress[got.progress.length - 1], ["verifying", size]);

    dir = path.join(work, "cache-keep");
    got = await fetchInto(lib, dir, archive, { size, sha256: sha }, true);
    assert.deepEqual(got.answer, { file: path.join(dir, sha + ".tar.gz"), cached: false }, "with keep the verified archive is the answer");
    assert.deepEqual(listing(dir), [sha + ".tar.gz"]);
    got = await fetchInto(lib, dir, path.join(work, "absent"), { size, sha256: sha }, true);
    assert.deepEqual(got.answer, { file: path.join(dir, sha + ".tar.gz"), cached: true }, "a verified archive in the cache is used");
    assert.deepEqual(got.progress[got.progress.length - 1], ["verifying", size]);

    dir = path.join(work, "cache-stale");
    fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dir, "other"), "kept");
    fs.symlinkSync(path.join(dir, "other"), path.join(dir, part));
    got = await fetchInto(lib, dir, archive, { size, sha256: sha }, false);
    assert.deepEqual(fs.readFileSync(got.answer.file), bytes, "a stale part is replaced");
    assert.equal(fs.readFileSync(path.join(dir, "other"), "utf8"), "kept", "a stale part's link target stays");

    // Refusals, each leaving no part.
    const REFUSALS = [
        ["a source shorter than the pin", archive, { size: size + 1, sha256: sha }, ["size", "got=" + size + " want=" + (size + 1)]],
        ["a source longer than the pin", archive, { size: size - 1, sha256: sha }, ["size", "got=" + size + " want=" + (size - 1)]],
        ["a source of another sha256", archive, { size, sha256: "0".repeat(64) }, ["sha256", "got=" + sha + " want=" + "0".repeat(64)]],
        ["an absent source", path.join(work, "absent"), { size, sha256: sha }, ["download", "error=ENOENT"]],
        ["a pin whose sha256 is no digest", archive, { size, sha256: "../x" }, ["pin", "size=" + size + " sha256=\"../x\""]],
        ["a pin whose size is no count", archive, { size: 0, sha256: sha }, ["pin", "size=0 sha256=\"" + sha + "\""]]
    ];
    for (const [label, source, pin, [reason, detail]] of REFUSALS) {
        dir = path.join(work, "cache-" + label.replace(/[^a-z0-9]+/g, "-"));
        got = await fetchInto(lib, dir, source, pin, false);
        assert.ok(got.refusal, label);
        assert.deepEqual([got.refusal.step, got.refusal.reason, got.refusal.detail], ["fetch", reason, detail], label);
        assert.deepEqual(listing(dir), [], label + " leaves no part");
        assert.ok(got.progress.every(([, n]) => n <= pin.size), label + " reports no byte past the pin");
    }

    // A cached archive that is no verified archive is refused where it is.
    dir = path.join(work, "cache-linked");
    fs.mkdirSync(dir);
    fs.symlinkSync(archive, path.join(dir, sha + ".tar.gz"));
    got = await fetchInto(lib, dir, archive, { size, sha256: sha }, false);
    assert.deepEqual([got.refusal.reason, got.refusal.detail], ["cache", "path=" + path.join(dir, sha + ".tar.gz") + " reason=not-file"], "a symlinked cache entry");
    dir = path.join(work, "cache-other");
    fs.mkdirSync(dir);
    const other = Buffer.from(bytes);
    other[0] ^= 1;
    fs.writeFileSync(path.join(dir, sha + ".tar.gz"), other);
    got = await fetchInto(lib, dir, archive, { size, sha256: sha }, false);
    assert.deepEqual([got.refusal.reason, got.refusal.detail], ["sha256", "path=" + path.join(dir, sha + ".tar.gz") + " got=" + sha256(other) + " want=" + sha], "a cache entry of other bytes");
}

const CONTROLS = [
    ['if (protocol === "https:" || (protocol === "file:" && allowFile)) return url;', 'return url;'],
    ['(protocol === "file:" && allowFile)', '(protocol === "file:")'],
    ['if (!Number.isSafeInteger(pin.size) || pin.size <= 0 || typeof pin.sha256 !== "string" || !SHA256_HEX.test(pin.sha256))', 'if (false)'],
    ['if (!stat.isFile()) throw new AssetRefusal("fetch", "cache"', 'if (false) throw new AssetRefusal("fetch", "cache"'],
    ['if (digest !== pin.sha256) throw new AssetRefusal("fetch", "sha256", "path="', 'if (false) throw new AssetRefusal("fetch", "sha256", "path="'],
    ['            if (bytes > pin.size) {', '            if (false) {'],
    ['if (bytes !== pin.size) throw new AssetRefusal', 'if (false) throw new AssetRefusal'],
    ['if (digest !== pin.sha256) throw new AssetRefusal("fetch", "sha256", "got="', 'if (false) throw new AssetRefusal("fetch", "sha256", "got="'],
    ['        fs.rmSync(part, { force: true });\n        if (e instanceof AssetRefusal) throw e;', '        if (e instanceof AssetRefusal) throw e;'],
    ['        fs.rmSync(part, { force: true });\n        fd = fs.openSync(part, "wx");', '        fd = fs.openSync(part, "wx");'],
    ['if (!/^[0-7]+$/.test(raw)) throw', 'if (false) throw'],
    ['if (stored !== actual) throw', 'if (false) throw'],
    ['if (Object.hasOwn(attrs, "size")) throw', 'if (false) throw'],
    ['if (Object.hasOwn(attrs, "path")) throw new AssetRefusal("header", "global-pax-path"', 'if (false) throw new AssetRefusal("header", "global-pax-path"'],
    ['if (Object.hasOwn(attrs, "path")) this.nextName = attrs.path;', ''],
    ['=== "ustar\\0" ? field(header, 345, 155) : ""', '=== "ustar\\0" ? "" : ""'],
    ['part === "" || part === "." || part === ".."', 'part === "." || part === ".."'],
    ['part === "" || part === "." || part === ".."', 'part === "" || part === ".."'],
    ['part === "" || part === "." || part === ".."', 'part === "" || part === "."'],
    ['if (this.body > 0 || this.skip > 0 || this.gatheredBytes > 0) throw', 'if (false) throw'],
    ['if (this.nextName !== null) throw', 'if (false) throw'],
    ['        reader.closeSink();\n', ''],
    ['            this.done = true;\n', '']
];

(async () => {
    try {
        await verify(require(libFile), fs.mkdtempSync(path.join(temp, "verify-")));
        const source = fs.readFileSync(libFile, "utf8");
        for (const [index, [needle, replacement]] of CONTROLS.entries()) {
            const label = "control " + index + " " + JSON.stringify(needle);
            assert.equal(source.split(needle).length, 2, label + ": the rule's text occurs once");
            // One file per control: require caches a module by its path.
            const copy = path.join(temp, "control-" + index + ".js");
            fs.writeFileSync(copy, source.replace(needle, replacement));
            let failed = false;
            try {
                await verify(require(copy), fs.mkdtempSync(path.join(temp, "control-" + index + "-")));
            } catch (e) {
                failed = true;
            }
            assert.ok(failed, label + ": the suite passed on a copy without that rule");
        }
        console.log(`test-theme-download: ok urls=${URLS.length} tars=${TARS.length} controls=${CONTROLS.length}`);
    } finally {
        fs.rmSync(temp, { recursive: true, force: true });
    }
})().catch(e => {
    console.error(e.stack || e);
    process.exit(1);
});
