"use strict";

// The one reader of the simple disk cache Slack's Electron client keeps,
// ~/.config/Slack/Cache/Cache_Data, read-only and with no credentials. Two
// callers read it: the workspace icons, through this file's `copy` verb,
// which WorkspaceIcons.qml runs under node, and the custom emoji,
// slack-emoji.js, through `list` and `read`.
//
// The format, read against Slack 4.52.162's Cache/Cache_Data on 2026-09-28
// and 2026-09-29:
// - A URL's entry is the file <hash>_0, where <hash> is the first 8 bytes of
//   the SHA-1 of the key "1/0/<url>" read as a little-endian number, in 16
//   hex digits.
// - The file opens with a 24-byte header whose bytes 12-15 are the key's
//   length, little-endian, then the key, then the body, then an end record
//   opening with the bytes d8 41 0d 97 45 6f fa f4, then the response
//   headers and their own end record. The body ends at the first end record
//   after the key.
//
// The rules the reader holds:
// - An entry opens only as a regular file, never through a link and never
//   blocking on a FIFO.
// - A read answers { ok: true, bytes }, the body, or { ok: false, reason },
//   reason one of missing, too-large, malformed or unreadable. An entry
//   keyed to another URL, with an empty body or without its end record is
//   malformed. Each caller names its bound, and a body past it is
//   too-large: the read stops at the bound, so a body not ended by then is
//   too-large while the file holds more bytes, and malformed when it does
//   not. The icons' bound is ICON_MAX, 5 MiB; the emoji's is
//   slack-emoji.js's SOURCE_MAX, 256 KiB.
// - A listing answers { entries, problem }: every entry whose key's URL
//   starts with the caller's prefix, as { url, mtimeMs }, in sorted file
//   order. It reads each file's header and key alone, at most KEY_MAX bytes
//   of key, and keeps an entry only when its file name is its key's hash. A
//   missing cache is no Slack on this machine and answers no entries and no
//   problem; an unreadable one is problem `unreadable`, and one past
//   LIST_MAX entries is refused as `too-many count=<n> want<=<LIST_MAX>`,
//   never cut short, so no entry is starved by the order.
//
//   node slack-cache.js copy <cache dir> <out dir> <to> <url>...
//
// empties <out dir>, then copies each URL's body to <to>, at most ICON_MAX,
// through <to>.tmp renamed into place. <out dir> holds only what this verb
// writes, so emptying it first drops the icons of a workspace that is gone.
// One stdout line per pair, which WorkspaceIcons.qml parses:
//   copied <to> version=<the first 16 hex digits of the body's SHA-256>
//   skipped <to> reason=<missing|too-large|malformed|unreadable>
// Every refusal is one keyed line on stderr, which WorkspaceIcons.qml logs:
//   exit 2  notifications-slack-cache: refused: usage
//   exit 3  notifications-slack-cache: refused: outside=<to> dir=<out dir>
//           (checked for every pair before anything is removed)
//   exit 4  notifications-slack-cache: error=<mkdir|list|remove|write> path=<path>

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const KEY_PREFIX = "1/0/";
const ENTRY_NAME = /^[0-9a-f]{16}_0$/;
const HEADER_BYTES = 24;
const KEY_LENGTH_AT = 12;
const END_RECORD = Buffer.from([0xd8, 0x41, 0x0d, 0x97, 0x45, 0x6f, 0xfa, 0xf4]);
// The longest key a listing reads.
const KEY_MAX = 256;
// The most entries one listing reads. The owner's cache held 17,765 on
// 2026-09-29.
const LIST_MAX = 262144;
// The largest icon body `copy` takes.
const ICON_MAX = 5 * 1024 * 1024;

// The file name of `url`'s entry.
function entryName(url) {
    const sum = crypto.createHash("sha1").update(Buffer.from(KEY_PREFIX + url, "utf8")).digest();
    return Buffer.from(sum.subarray(0, 8)).reverse().toString("hex") + "_0";
}

// A regular file opened for reading, never through a link and never
// blocking on a FIFO: { fd } or { reason }.
function openEntry(file) {
    let fd;
    try {
        fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    } catch (e) {
        return { reason: e.code === "ENOENT" ? "missing" : "unreadable" };
    }
    try {
        if (fs.fstatSync(fd).isFile()) return { fd };
    } catch (_e) {
        // Not a file the reader can judge.
    }
    fs.closeSync(fd);
    return { reason: "unreadable" };
}

function readFully(fd, length) {
    const bytes = Buffer.alloc(length);
    let read = 0;
    while (read < length) {
        const got = fs.readSync(fd, bytes, read, length - read, read);
        if (got === 0) break;
        read += got;
    }
    return bytes.subarray(0, read);
}

// The body of `url`'s entry in `dir`, at most `max` bytes.
function read(dir, url, max) {
    const key = Buffer.from(KEY_PREFIX + url, "utf8");
    const opened = openEntry(path.join(dir, entryName(url)));
    if (opened.fd === undefined) return { ok: false, reason: opened.reason };
    try {
        const size = fs.fstatSync(opened.fd).size;
        const start = HEADER_BYTES + key.length;
        const limit = Math.min(size, start + max + END_RECORD.length);
        const bytes = readFully(opened.fd, Math.max(limit, 0));
        if (bytes.length < start || bytes.readUInt32LE(KEY_LENGTH_AT) !== key.length || !bytes.subarray(HEADER_BYTES, start).equals(key))
            return { ok: false, reason: "malformed" };
        const end = bytes.indexOf(END_RECORD, start);
        if (end === -1) return { ok: false, reason: size > limit ? "too-large" : "malformed" };
        if (end === start) return { ok: false, reason: "malformed" };
        return { ok: true, bytes: Buffer.from(bytes.subarray(start, end)) };
    } catch (_e) {
        return { ok: false, reason: "unreadable" };
    } finally {
        fs.closeSync(opened.fd);
    }
}

// Every entry in `dir` whose key's URL starts with `urlPrefix`.
function list(dir, urlPrefix) {
    const entries = [];
    let names;
    try {
        names = fs.readdirSync(dir);
    } catch (e) {
        return { entries, problem: e.code === "ENOENT" ? "" : "unreadable" };
    }
    const found = names.filter(name => ENTRY_NAME.test(name)).sort();
    if (found.length > LIST_MAX) return { entries, problem: "too-many count=" + found.length + " want<=" + LIST_MAX };
    const want = Buffer.from(KEY_PREFIX + urlPrefix, "utf8");
    const head = Buffer.alloc(HEADER_BYTES + KEY_MAX);
    for (const name of found) {
        const opened = openEntry(path.join(dir, name));
        if (opened.fd === undefined) continue;
        let got = 0;
        let mtimeMs = 0;
        try {
            mtimeMs = fs.fstatSync(opened.fd).mtimeMs;
            got = fs.readSync(opened.fd, head, 0, head.length, 0);
        } catch (_e) {
            got = 0;
        } finally {
            fs.closeSync(opened.fd);
        }
        if (got < HEADER_BYTES) continue;
        const keyLength = head.readUInt32LE(KEY_LENGTH_AT);
        if (keyLength < want.length || keyLength > KEY_MAX || HEADER_BYTES + keyLength > got) continue;
        const key = head.subarray(HEADER_BYTES, HEADER_BYTES + keyLength);
        if (!key.subarray(0, want.length).equals(want)) continue;
        const url = key.toString("utf8", KEY_PREFIX.length);
        if (entryName(url) !== name) continue;
        entries.push({ url, mtimeMs });
    }
    return { entries, problem: "" };
}

function refuse(status, line) {
    process.stderr.write("notifications-slack-cache: " + line + "\n");
    process.exit(status);
}

// The `copy` verb; `args` follow the verb.
function copy(args) {
    if (args.length < 2 || args.length % 2 !== 0) refuse(2, "refused: usage");
    const [cacheDir, dir] = args;
    const pairs = [];
    for (let i = 2; i < args.length; i += 2) {
        const to = args[i];
        const name = to.slice(to.lastIndexOf("/") + 1);
        if (to !== dir + "/" + name || name === "" || name === "." || name === "..") refuse(3, "refused: outside=" + to + " dir=" + dir);
        pairs.push({ to, url: args[i + 1] });
    }
    try {
        fs.mkdirSync(dir, { recursive: true });
    } catch (_e) {
        refuse(4, "error=mkdir path=" + dir);
    }
    let names;
    try {
        names = fs.readdirSync(dir);
    } catch (_e) {
        refuse(4, "error=list path=" + dir);
    }
    for (const name of names) {
        const file = path.join(dir, name);
        try {
            fs.rmSync(file, { force: true });
        } catch (_e) {
            refuse(4, "error=remove path=" + file);
        }
    }
    for (const { to, url } of pairs) {
        const body = read(cacheDir, url, ICON_MAX);
        if (!body.ok) {
            process.stdout.write("skipped " + to + " reason=" + body.reason + "\n");
            continue;
        }
        try {
            fs.writeFileSync(to + ".tmp", body.bytes);
            fs.renameSync(to + ".tmp", to);
        } catch (_e) {
            try {
                fs.rmSync(to + ".tmp", { force: true });
            } catch (_ignored) {
                // The write's failure is the one reported; the next copy
                // empties the directory again.
            }
            refuse(4, "error=write path=" + to);
        }
        const version = crypto.createHash("sha256").update(body.bytes).digest("hex").slice(0, 16);
        process.stdout.write("copied " + to + " version=" + version + "\n");
    }
}

if (require.main === module) {
    const [verb, ...args] = process.argv.slice(2);
    if (verb !== "copy") refuse(2, "refused: usage");
    copy(args);
}

module.exports = { list, read };
