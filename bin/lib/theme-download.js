// The verified fetch and the tar reader `vgsh theme wallpapers`
// (bin/vgsh-theme-judge) and tools/convert-v1-themes share: a theme's
// wallpaper archive, pinned by a catalog entry's `imagery` `{ repo,
// release, archive, size, sha256 }`, streamed into the cache, checked
// against the pin, then read member by member. Each caller keeps its own
// member policy and its own refusal lines; this file refuses through
// AssetRefusal, which names the step and a stable reason.
//
// The cache is `${XDG_CACHE_HOME:-$HOME/.cache}/vgs/theme-assets/`: a
// download streams into `<sha256>.tar.gz.part`, hashed and counted as it
// is written and cut off once it passes the pinned size, and a caller that
// keeps it renames it to `<sha256>.tar.gz`. `download.lock` there is the
// lock `vgsh theme wallpapers` holds for the whole fetch.
// docs/architecture/theme-wallpapers.md.
"use strict";
const crypto = require("crypto");
const fs = require("fs");
const https = require("https");
const os = require("os");
const path = require("path");
const zlib = require("zlib");
const { Writable } = require("stream");
const { pipeline } = require("stream/promises");
const { fileURLToPath } = require("url");

// The most bytes one unpacked member may hold, v1's CATALOG_MAX_FILE_BYTES.
const MEMBER_CEILING = 128 * 1024 * 1024;
// A download ends when no byte arrived for this long, v1's CATALOG_TIMEOUT.
const IDLE_TIMEOUT_MS = 60 * 1000;
// The redirects one download follows; a GitHub release asset takes one.
const REDIRECT_LIMIT = 5;
const REDIRECTS = [301, 302, 303, 307, 308];
const LOCK_FILE = "download.lock";
const SHA256_HEX = /^[0-9a-f]{64}$/;
const BLOCK = 512;

// A refusal of this file. STEP is where it arose: `fetch` for the URL, the
// transfer, the cache and the pin check, `archive` for the gzip stream and
// the file under it, `header` for a tar header, `name` for a member name
// no package may hold. REASON is the key within the step, DETAIL its
// `key=value` fields, MEMBER the refused member's raw name or null.
class AssetRefusal extends Error {
    constructor(step, reason, detail, member = null) {
        super(step + ": " + reason + (detail === "" ? "" : " " + detail));
        this.step = step;
        this.reason = reason;
        this.detail = detail;
        this.member = member;
    }
}

// The theme-asset cache directory, from the environment ENV.
function cacheDir(env = process.env) {
    return path.join(env.XDG_CACHE_HOME || path.join(env.HOME || os.homedir(), ".cache"), "vgs", "theme-assets");
}

// The URL of PIN's archive, `<base>/<release>/<archive>`, BASE defaulting to
// the pin's `<repo>/releases/download`. HTTPS always; `file://` only with
// ALLOW_FILE, for a test's fixture archives. The pin, not the URL, decides
// which bytes are accepted.
function archiveUrl(pin, base, allowFile) {
    const root = (base === undefined || base === null || base === "" ? pin.repo + "/releases/download" : base).replace(/\/+$/, "");
    const url = root + "/" + encodeURIComponent(pin.release) + "/" + encodeURIComponent(pin.archive);
    let protocol;
    try {
        protocol = new URL(url).protocol;
    } catch (e) {
        throw new AssetRefusal("fetch", "not-https", "url=" + JSON.stringify(url));
    }
    if (protocol === "https:" || (protocol === "file:" && allowFile)) return url;
    throw new AssetRefusal("fetch", "not-https", "url=" + JSON.stringify(url));
}

// The pin's size and sha256 as a path and a byte count may use them; a pin
// no index judge accepted may carry neither.
function checkPin(pin) {
    if (!Number.isSafeInteger(pin.size) || pin.size <= 0 || typeof pin.sha256 !== "string" || !SHA256_HEX.test(pin.sha256))
        throw new AssetRefusal("fetch", "pin", "size=" + JSON.stringify(pin.size) + " sha256=" + JSON.stringify(pin.sha256));
}

// Write all of CHUNK to FD, a write(2) that returns short included.
function writeAll(fd, chunk) {
    for (let at = 0; at < chunk.length;) at += fs.writeSync(fd, chunk, at, chunk.length - at);
}

// Whether the verified archive FILE is in the cache: false when nothing is
// there, true once its size and sha256 match PIN. Anything else there is
// refused: a symlink or non-file `cache`, other bytes `size` or `sha256`.
async function cached(file, pin, progress) {
    const stat = fs.lstatSync(file, { throwIfNoEntry: false });
    if (stat === undefined) return false;
    if (!stat.isFile()) throw new AssetRefusal("fetch", "cache", "path=" + file + " reason=not-file");
    if (stat.size !== pin.size) throw new AssetRefusal("fetch", "size", "path=" + file + " got=" + stat.size + " want=" + pin.size);
    const hash = crypto.createHash("sha256");
    let bytes = 0;
    progress("verifying", 0);
    for await (const chunk of fs.createReadStream(file)) {
        hash.update(chunk);
        bytes += chunk.length;
        progress("verifying", bytes);
    }
    const digest = hash.digest("hex");
    if (digest !== pin.sha256) throw new AssetRefusal("fetch", "sha256", "path=" + file + " got=" + digest + " want=" + pin.sha256);
    return true;
}

// The idle deadline of one download: the stream `watch` last named is
// destroyed with the `timeout` refusal once no byte arrived for
// IDLE_TIMEOUT_MS.
function idleDeadline() {
    let stream = null;
    const timer = setTimeout(() => stream.destroy(new AssetRefusal("fetch", "download", "error=timeout")), IDLE_TIMEOUT_MS);
    return {
        watch(next) { stream = next; timer.refresh(); },
        tick() { timer.refresh(); },
        stop() { clearTimeout(timer); }
    };
}

// The 200 response to GET URL, following up to REDIRECTS more redirects,
// each to HTTPS only.
function httpsResponse(url, redirects, idle) {
    return new Promise((resolve, reject) => {
        const request = https.get(url, { headers: { "User-Agent": "vgsh" } }, response => {
            const status = response.statusCode;
            if (REDIRECTS.includes(status)) {
                response.resume();
                let next;
                try {
                    next = new URL(response.headers.location, url);
                } catch (e) {
                    reject(new AssetRefusal("fetch", "download", "status=" + status + " location=" + JSON.stringify(response.headers.location ?? null)));
                    return;
                }
                if (next.protocol !== "https:") reject(new AssetRefusal("fetch", "redirect-not-https", "url=" + JSON.stringify(next.href)));
                else if (redirects === 0) reject(new AssetRefusal("fetch", "download", "error=redirects limit=" + REDIRECT_LIMIT));
                else httpsResponse(next.href, redirects - 1, idle).then(resolve, reject);
                return;
            }
            if (status !== 200) {
                response.resume();
                reject(new AssetRefusal("fetch", "download", "status=" + status));
                return;
            }
            idle.watch(response);
            resolve(response);
        });
        idle.watch(request);
        request.on("error", reject);
    });
}

// The stream of URL's bytes: a file for `file://`, else the HTTPS response.
async function source(url, idle) {
    if (url.startsWith("file:")) {
        const stream = fs.createReadStream(fileURLToPath(url));
        idle.watch(stream);
        return stream;
    }
    return httpsResponse(url, REDIRECT_LIMIT, idle);
}

// Fetch PIN's archive from URL, archiveUrl's answer, into DIR, the cache.
// A verified `<sha256>.tar.gz` already there is used as it is. Otherwise
// the bytes stream into `<sha256>.tar.gz.part`, which the caller's lock
// makes this process's own, so a part already there is stale and removed.
// Each chunk is hashed as it is written, and the transfer is cut off once
// it passes PIN's size; the part is then refused unless its size and
// sha256 are PIN's. With KEEP the verified part is renamed to
// `<sha256>.tar.gz`; without it the caller reads the part and removes it.
// A refusal removes the part. PROGRESS(state, bytes) hears `downloading`
// and `verifying`. Answers `{ file, cached }`: the verified file, and
// whether it was already in the cache, which a caller that removes its
// part leaves alone. The archive is never held whole in memory.
async function fetchArchive(pin, url, dir, keep, progress) {
    checkPin(pin);
    const final = path.join(dir, pin.sha256 + ".tar.gz");
    if (await cached(final, pin, progress)) return { file: final, cached: true };
    const part = final + ".part";
    let fd;
    try {
        fs.mkdirSync(dir, { recursive: true });
        fs.rmSync(part, { force: true });
        fd = fs.openSync(part, "wx");
    } catch (e) {
        throw new AssetRefusal("fetch", "unwritable", "path=" + part + " error=" + e.code);
    }
    const hash = crypto.createHash("sha256");
    const idle = idleDeadline();
    let bytes = 0;
    const sink = new Writable({
        write(chunk, _encoding, done) {
            idle.tick();
            bytes += chunk.length;
            if (bytes > pin.size) {
                done(new AssetRefusal("fetch", "size", "got=" + bytes + " want=" + pin.size));
                return;
            }
            hash.update(chunk);
            try {
                writeAll(fd, chunk);
            } catch (e) {
                done(new AssetRefusal("fetch", "unwritable", "path=" + part + " error=" + e.code));
                return;
            }
            progress("downloading", bytes);
            done();
        }
    });
    try {
        progress("downloading", 0);
        await pipeline(await source(url, idle), sink);
        fs.closeSync(fd);
        fd = undefined;
        progress("verifying", bytes);
        if (bytes !== pin.size) throw new AssetRefusal("fetch", "size", "got=" + bytes + " want=" + pin.size);
        const digest = hash.digest("hex");
        if (digest !== pin.sha256) throw new AssetRefusal("fetch", "sha256", "got=" + digest + " want=" + pin.sha256);
        if (!keep) return { file: part, cached: false };
        fs.renameSync(part, final);
        return { file: final, cached: false };
    } catch (e) {
        if (fd !== undefined) fs.closeSync(fd);
        fs.rmSync(part, { force: true });
        if (e instanceof AssetRefusal) throw e;
        if (typeof e.code === "string" && e.syscall === "rename") throw new AssetRefusal("fetch", "unwritable", "path=" + final + " error=" + e.code);
        throw new AssetRefusal("fetch", "download", "error=" + (typeof e.code === "string" ? e.code : JSON.stringify(e.message)));
    } finally {
        idle.stop();
    }
}

// --- the tar reader

// A tar member's kind from its typeflag: regular files are `0` or NUL,
// which reads as "".
const KINDS = { "": "file", "0": "file", "1": "hardlink", "2": "symlink", "5": "directory" };

// The bytes after a body of SIZE up to the next block.
function padding(size) {
    return (BLOCK - (size % BLOCK)) % BLOCK;
}

function field(header, start, length) {
    return header.subarray(start, start + length).toString("utf8").replace(/\0.*$/s, "");
}

// The octal number in a header field; base-256 and every other form are
// refused as the header defect DEFECT.
function octal(header, start, length, defect) {
    const raw = header.subarray(start, start + length).toString("latin1").replace(/\0/g, " ").trim();
    if (!/^[0-7]+$/.test(raw)) throw new AssetRefusal("header", defect, "value=" + JSON.stringify(raw));
    return parseInt(raw, 8);
}

function verifyChecksum(header) {
    const stored = octal(header, 148, 8, "checksum");
    let actual = 0;
    for (let index = 0; index < BLOCK; index++) actual += index >= 148 && index < 156 ? 32 : header[index];
    if (stored !== actual) throw new AssetRefusal("header", "checksum", "got=" + stored + " want=" + actual);
}

// The records of a pax header's DATA, `<length> <key>=<value>\n` each.
function paxRecords(data) {
    const attrs = {};
    for (let at = 0; at < data.length;) {
        const space = data.indexOf(32, at);
        if (space === -1) throw new AssetRefusal("header", "pax", "at=" + at);
        const rawLength = data.subarray(at, space).toString("latin1");
        const length = /^[0-9]+$/.test(rawLength) ? Number(rawLength) : NaN;
        if (!Number.isSafeInteger(length) || length <= 0 || at + length > data.length || data[at + length - 1] !== 10)
            throw new AssetRefusal("header", "pax-length", "at=" + at);
        const record = data.subarray(space + 1, at + length - 1).toString("utf8");
        const equals = record.indexOf("=");
        if (equals <= 0) throw new AssetRefusal("header", "pax-record", "at=" + at);
        attrs[record.slice(0, equals)] = record.slice(equals + 1);
        at += length;
    }
    return attrs;
}

// RAW as a member name: trailing slashes and each leading `./` dropped.
// A name with an empty, `.` or `..` segment is refused, an absolute one
// included, whose first segment is empty: no package holds it.
function memberName(raw) {
    let name = raw.replace(/\/+$/, "");
    while (name.startsWith("./")) name = name.slice(2);
    if (name.split("/").some(part => part === "" || part === "." || part === "..")) throw new AssetRefusal("name", "path", "", raw);
    return name;
}

// A push parser of an uncompressed tar stream. Each chunk goes to push()
// in order, then end() once the stream ends. Every header's checksum is
// verified and its size read as octal. A pax `x` header's `path` names the
// next member and a pax `size` is refused; a global pax `g` header is
// accepted only without a `path`; a GNU `L` header's body names the next
// member. Every other member goes to POLICY as `{ name, type, kind, size }`,
// NAME as memberName answers it, TYPE the raw typeflag and KIND `file`,
// `hardlink`, `symlink`, `directory` or `other`. POLICY answers null to
// skip the body, or a sink `{ write(chunk), close() }` that is handed the
// body chunk by chunk and closed after its last byte; it refuses by
// throwing. Reading stops at the first zero block.
class TarReader {
    constructor(policy) {
        this.policy = policy;
        // The bytes being gathered for THEN: a header block or a pax or
        // long-name body.
        this.gathered = [];
        this.gatheredBytes = 0;
        this.want = BLOCK;
        this.then = header => this.header(header);
        // The member body still to hand to SINK, null for a skipped one,
        // and the padding after it.
        this.body = 0;
        this.sink = null;
        this.padding = 0;
        this.skip = 0;
        this.nextName = null;
        this.done = false;
    }

    push(chunk) {
        let at = 0;
        while (at < chunk.length && !this.done) {
            if (this.skip > 0) {
                const take = Math.min(this.skip, chunk.length - at);
                this.skip -= take;
                at += take;
            } else if (this.body > 0) {
                const take = Math.min(this.body, chunk.length - at);
                if (this.sink !== null) this.sink.write(chunk.subarray(at, at + take));
                this.body -= take;
                at += take;
                if (this.body === 0) this.endBody();
            } else {
                const take = Math.min(this.want - this.gatheredBytes, chunk.length - at);
                this.gathered.push(chunk.subarray(at, at + take));
                this.gatheredBytes += take;
                at += take;
                if (this.gatheredBytes === this.want) {
                    const data = Buffer.concat(this.gathered);
                    this.gathered = [];
                    this.gatheredBytes = 0;
                    this.then(data);
                }
            }
        }
    }

    end() {
        if (this.done) return;
        if (this.body > 0 || this.skip > 0 || this.gatheredBytes > 0) throw new AssetRefusal("header", "truncated", "");
        if (this.nextName !== null) throw new AssetRefusal("header", "long-name", "name=" + JSON.stringify(this.nextName));
    }

    // Close the open sink, if any: after its member's last byte, or when
    // the read fails part way.
    closeSink() {
        const sink = this.sink;
        this.sink = null;
        if (sink !== null) sink.close();
    }

    endBody() {
        this.closeSink();
        this.skip = this.padding;
        this.padding = 0;
    }

    // Gather the next WANT bytes, a pax or long-name body, for THEN, skip
    // the padding after them and read a header next.
    gather(want, then) {
        this.want = want;
        this.then = data => {
            this.want = BLOCK;
            this.then = header => this.header(header);
            this.skip = padding(want);
            then(data);
        };
        if (want === 0) this.then(Buffer.alloc(0));
    }

    header(header) {
        if (header.every(byte => byte === 0)) {
            this.done = true;
            return;
        }
        verifyChecksum(header);
        const size = octal(header, 124, 12, "size");
        const type = field(header, 156, 1);
        if (type === "x") {
            this.gather(size, data => {
                const attrs = paxRecords(data);
                if (Object.hasOwn(attrs, "size")) throw new AssetRefusal("header", "pax-size", "size=" + JSON.stringify(attrs.size));
                if (Object.hasOwn(attrs, "path")) this.nextName = attrs.path;
            });
            return;
        }
        if (type === "g") {
            this.gather(size, data => {
                const attrs = paxRecords(data);
                if (Object.hasOwn(attrs, "path")) throw new AssetRefusal("header", "global-pax-path", "path=" + JSON.stringify(attrs.path));
            });
            return;
        }
        if (type === "L") {
            this.gather(size, data => { this.nextName = data.toString("utf8").replace(/\0.*$/s, "").replace(/\n$/, ""); });
            return;
        }
        const prefix = header.subarray(257, 263).toString("latin1") === "ustar\0" ? field(header, 345, 155) : "";
        const raw = this.nextName ?? (prefix === "" ? field(header, 0, 100) : prefix + "/" + field(header, 0, 100));
        this.nextName = null;
        this.sink = this.policy({ name: memberName(raw), type, kind: KINDS[type] ?? "other", size });
        this.body = size;
        this.padding = padding(size);
        if (size === 0) this.endBody();
    }
}

// Read the gzip tar FILE through a TarReader with POLICY. PROGRESS(state,
// bytes) hears `unpacking` with the compressed bytes read. A gzip error is
// refused `archive gzip`, a file that cannot be read `archive unreadable`;
// a refusal of the reader or of POLICY passes through as it was thrown,
// with the open sink closed.
async function readArchive(file, policy, progress) {
    const reader = new TarReader(policy);
    const input = fs.createReadStream(file);
    try {
        progress("unpacking", 0);
        await pipeline(input, zlib.createGunzip(), async function (chunks) {
            for await (const chunk of chunks) {
                reader.push(chunk);
                progress("unpacking", input.bytesRead);
            }
        });
        reader.end();
    } catch (e) {
        reader.closeSink();
        if (typeof e.code === "string" && e.code.startsWith("Z_")) throw new AssetRefusal("archive", "gzip", "error=" + e.code);
        if (typeof e.code === "string" && typeof e.syscall === "string") throw new AssetRefusal("archive", "unreadable", "path=" + file + " error=" + e.code);
        throw e;
    }
}

module.exports = { MEMBER_CEILING, LOCK_FILE, AssetRefusal, cacheDir, archiveUrl, fetchArchive, writeAll, TarReader, readArchive };
