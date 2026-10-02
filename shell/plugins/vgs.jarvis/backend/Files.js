// The files executor: list, read, search, write, move and delete with Node's
// fs under Denied.js. Each call rejudges its paths with a fresh snapshot and
// then opens only through held directory descriptors (Anchored.js), so a
// component swapped for a link after that judge is refused, not followed.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const Tools = require("./Tools.js");
const Anchored = require("./Anchored.js");
const { O_RDONLY, O_WRONLY, O_CREAT, O_EXCL, O_DIRECTORY, O_NOFOLLOW, O_NONBLOCK, O_NOCTTY } = fs.constants;

/**
 * Production bounds in entries, bytes, levels and milliseconds. They are
 * recovery and resource ceilings for a large tree or file, not measured
 * budgets. Tests pass smaller ones.
 */
const BOUNDS = Object.freeze({
    listEntries: 512, readBytes: 1024 * 1024, writeBytes: 1024 * 1024,
    searchDepth: 8, searchEntries: 20000, searchBytes: 16 * 1024 * 1024,
    searchMatches: 100, lineChars: 200, searchMs: 10000,
    deleteEntries: 4096, deleteDepth: 32,
    // Scheduling slack between the executor's own bounds and Session's limit.
    slackMs: 1000
});

// An executor's answer, thrown to end a call early.
class Ended {
    constructor(outcome, content) { this.value = { outcome, content }; }
}
const failed = content => new Ended("failed", content);
const refused = (reason, file) => failed("Refused: " + reason + " for " + file + ".");
// The judge resolved every link and saw every component, so a link, a gap or
// a different kind found while opening appeared after that judge.
const changed = file => refused("path-changed", file);

// A Node failure by its code. No raw error object reaches a result.
function cause(error) {
    if (error instanceof Ended) throw error;
    if (typeof error?.code === "string" && /^E[A-Z0-9]+$/.test(error.code)) return error.code;
    throw error;
}

function kindOf(stat) {
    return stat.isFile() ? "file" : stat.isDirectory() ? "directory" : stat.isSymbolicLink() ? "link" : "other";
}

// The kind in a sentence, for a refusal of the wrong kind.
function described(stat) {
    return stat.isFile() ? "a file" : stat.isDirectory() ? "a folder" : stat.isSymbolicLink() ? "a link"
        : stat.isFIFO() ? "a fifo" : stat.isSocket() ? "a socket" : "a device";
}

function close(fd) {
    if (fd !== undefined) fs.closeSync(fd);
}

/**
 * Hold the parent folder of a judged physical path, opened from "/" one
 * component at a time, and pass its descriptor and the entry's name to act.
 * absent is the answer when the parent no longer exists.
 */
function inParent(file, act, absent = () => changed(file)) {
    const opened = Anchored.directory(path.dirname(file));
    switch (opened.kind) {
    case "directory": break;
    case "absent": throw absent();
    case "unreadable": throw failed("The folder of " + file + " could not be read: " + opened.code + ".");
    case "link": case "not-directory": case "unreadable-or-changed": throw changed(file);
    default: throw new Error("jarvis: files=walk-kind");
    }
    try { return act(opened.fd, path.basename(file)); }
    finally { fs.closeSync(opened.fd); }
}

// lstat an entry in a held folder; an absent entry is absent: null.
function entry(parent, name) {
    try { return fs.lstatSync(Anchored.child(parent, name)); }
    catch (error) {
        if (error.code === "ENOENT") return null;
        throw failed("The entry " + name + " could not be read: " + cause(error) + ".");
    }
}

// Open an entry in a held folder without following a link in its place.
function openIn(parent, name, file, flags) {
    try { return fs.openSync(Anchored.child(parent, name), flags | O_NOFOLLOW); }
    catch (error) {
        if (["ELOOP", "ENOENT", "ENOTDIR"].includes(error.code)) throw changed(file);
        throw failed(file + " could not be opened: " + cause(error) + ".");
    }
}

// Read at most limit bytes, sized first by the expected length; null when
// the file holds more.
function readBounded(fd, limit, expected) {
    let buffer = Buffer.alloc(Math.min(limit, expected) + 1);
    let size = 0;
    for (;;) {
        if (size === buffer.length) {
            if (size > limit) return null;
            const larger = Buffer.alloc(Math.min(limit + 1, buffer.length * 2));
            buffer.copy(larger);
            buffer = larger;
        }
        const read = fs.readSync(fd, buffer, size, buffer.length - size, null);
        if (read === 0) return buffer.subarray(0, size);
        size += read;
    }
}

// UTF-8 text, or null for a file holding NUL or invalid UTF-8.
function text(bytes) {
    if (bytes.includes(0)) return null;
    try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
    catch { return null; }
}

/**
 * create({denied, bounds, clock}) builds the files executor record.
 * denied() returns a fresh Denied.create snapshot or throws; it is called
 * once per call, immediately before the act. clock.now() reads milliseconds
 * for the search's wall-time bound.
 */
function create({ denied, bounds = BOUNDS, clock }) {
    let closed = false;

    function list(target, file) {
        if (!target.exists) throw failed(file + " does not exist.");
        const names = inParent(target.path, (parent, name) => {
            const stat = entry(parent, name);
            if (stat === null || stat.isSymbolicLink()) throw changed(target.path);
            if (!stat.isDirectory()) throw failed(target.path + " is " + described(stat) + ", not a folder.");
            const fd = openIn(parent, name, target.path, O_RDONLY | O_DIRECTORY);
            let folder;
            try {
                folder = fs.opendirSync(Anchored.child(fd, "."));
                const rows = [];
                let cut = false;
                for (let item; (item = folder.readSync()) !== null;) {
                    if (rows.length === bounds.listEntries) { cut = true; break; }
                    // Metadata only: a child is named and measured, never opened.
                    const child = entry(fd, item.name);
                    if (child !== null) rows.push({ name: item.name, kind: kindOf(child), size: child.isFile() ? child.size : null });
                }
                return { rows, cut };
            } catch (error) {
                if (error instanceof Ended) throw error;
                throw failed(target.path + " could not be listed: " + cause(error) + ".");
            } finally {
                if (folder !== undefined) folder.closeSync();
                fs.closeSync(fd);
            }
        });
        names.rows.sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
        const lines = names.rows.map(row => row.kind + " " + JSON.stringify(row.name) + (row.size === null ? "" : " " + row.size + " bytes"));
        const head = names.rows.length + " entries in " + target.path
            + (names.cut ? " (list cut at " + bounds.listEntries + " entries; the rest are unnamed)" : "");
        return { outcome: "completed", content: [head].concat(lines).join("\n") };
    }

    function read(target, file) {
        if (!target.exists) throw failed(file + " does not exist.");
        return inParent(target.path, (parent, name) => {
            const stat = entry(parent, name);
            if (stat === null || stat.isSymbolicLink()) throw changed(target.path);
            // A device, fifo or socket is refused before any open.
            if (!stat.isFile()) throw failed(target.path + " is " + described(stat) + "; files.read reads regular files only.");
            if (stat.size > bounds.readBytes)
                throw failed(target.path + " holds " + stat.size + " bytes, over the " + bounds.readBytes + " byte read ceiling.");
            const fd = openIn(parent, name, target.path, O_RDONLY | O_NONBLOCK | O_NOCTTY);
            try {
                const opened = fs.fstatSync(fd);
                if (!opened.isFile()) throw changed(target.path);
                const bytes = readBounded(fd, bounds.readBytes, opened.size);
                if (bytes === null) throw failed(target.path + " grew past the " + bounds.readBytes + " byte read ceiling.");
                const content = text(bytes);
                if (content === null)
                    throw failed(target.path + " is binary or not UTF-8 text (" + bytes.length + " bytes); its content is not returned.");
                return { outcome: "completed", content: content === "" ? target.path + " is empty." : content };
            } catch (error) {
                if (error instanceof Ended) throw error;
                throw failed(target.path + " could not be read: " + cause(error) + ".");
            } finally { fs.closeSync(fd); }
        });
    }

    /**
     * One level per event-loop turn: the daemon's audio pacing shares the
     * loop. Folders wait on a stack holding their parent's descriptor; a
     * parent closes once its last waiting child has opened.
     */
    function search(target, file, query, snapshot) {
        if (!target.exists) throw failed(file + " does not exist.");
        const opened = Anchored.directory(target.path);
        if (opened.kind === "absent" || opened.kind === "link" || opened.kind === "unreadable-or-changed") throw changed(target.path);
        if (opened.kind === "not-directory") throw failed(target.path + " is not a folder.");
        if (opened.kind === "unreadable") throw failed(target.path + " could not be read: " + opened.code + ".");
        const started = clock.now();
        const needle = query.toLowerCase();
        const skipped = { links: 0, protected: 0, binary: 0, large: 0, deep: 0, unreadable: 0 };
        const matches = [];
        const stack = [];
        let visited = 0, bytes = 0, cut = null;

        const release = handle => { if (--handle.refs === 0) fs.closeSync(handle.fd); };
        const match = line => {
            if (matches.length === bounds.searchMatches) { cut = "matches"; return; }
            matches.push(line);
        };
        const clip = line => {
            const plain = line.replace(/[\x00-\x1f\x7f]/g, " ");
            return plain.length > bounds.lineChars ? plain.slice(0, bounds.lineChars) + "..." : plain;
        };

        function lines(folder, name, child) {
            let fd;
            try { fd = fs.openSync(Anchored.child(folder, name), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY); }
            catch (error) { if (error.code === "ELOOP") skipped.links++; else skipped.unreadable++; return; }
            try {
                const stat = fs.fstatSync(fd);
                if (!stat.isFile()) { skipped.unreadable++; return; }
                const data = readBounded(fd, bounds.readBytes, stat.size);
                if (data === null) { skipped.large++; return; }
                bytes += data.length;
                const content = text(data);
                if (content === null) { skipped.binary++; return; }
                const rows = content.split("\n");
                for (let i = 0; i < rows.length && cut === null; i++)
                    if (rows[i].toLowerCase().includes(needle)) match(child + ":" + (i + 1) + ": " + clip(rows[i]));
            } catch (error) {
                cause(error);
                skipped.unreadable++;
            } finally { fs.closeSync(fd); }
        }

        function scan(handle, folder, depth) {
            let entries;
            try { entries = fs.readdirSync(Anchored.child(handle.fd, "."), { withFileTypes: true }); }
            catch (error) { cause(error); skipped.unreadable++; return; }
            entries.sort((left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
            const folders = [];
            for (const item of entries) {
                if (cut !== null) break;
                if (++visited > bounds.searchEntries) { cut = "entries"; break; }
                if (clock.now() - started >= bounds.searchMs) { cut = "time"; break; }
                const child = path.join(folder, item.name);
                let stat;
                try { stat = fs.lstatSync(Anchored.child(handle.fd, item.name)); }
                catch (error) { cause(error); skipped.unreadable++; continue; }
                if (stat.isSymbolicLink()) { skipped.links++; continue; }
                // Every child is judged before its name is used or it opens.
                if (snapshot.inspect(child, "read").kind !== "path") { skipped.protected++; continue; }
                if (item.name.toLowerCase().includes(needle)) match(child);
                if (stat.isDirectory()) {
                    if (depth === bounds.searchDepth) skipped.deep++;
                    else folders.push({ name: item.name, path: child, depth: depth + 1 });
                } else if (stat.isFile()) {
                    if (stat.size > bounds.readBytes) { skipped.large++; continue; }
                    if (bytes + stat.size > bounds.searchBytes) { cut = "bytes"; break; }
                    lines(handle.fd, item.name, child);
                }
            }
            for (const next of folders.reverse()) {
                handle.refs++;
                stack.push({ parent: handle, ...next });
            }
        }

        function answer() {
            const head = matches.length + " matches for " + JSON.stringify(query) + " under " + target.path
                + (cut === null ? "" : "; stopped at the " + cut + " bound") + ".";
            const skips = "Skipped: " + skipped.links + " links, " + skipped.protected + " protected, "
                + skipped.binary + " binary or not UTF-8, " + skipped.large + " over " + bounds.readBytes + " bytes, "
                + skipped.deep + " folders deeper than " + bounds.searchDepth + " levels, " + skipped.unreadable + " unreadable or changed.";
            return { outcome: "completed", content: [head, skips].concat(matches).join("\n") };
        }

        return new Promise((resolve, reject) => {
            const end = value => {
                for (const waiting of stack.splice(0)) release(waiting.parent);
                if (value instanceof Error) reject(value); else resolve(value);
            };
            const visit = (handle, folder, depth) => {
                try { scan(handle, folder, depth); }
                finally { release(handle); }
            };
            function step() {
                try {
                    if (closed) { end({ outcome: "failed", content: "The search stopped: Jarvis is closing." }); return; }
                    if (cut === null && clock.now() - started >= bounds.searchMs) cut = "time";
                    const next = cut === null ? stack.pop() : undefined;
                    if (next === undefined) { end(answer()); return; }
                    let fd;
                    try { fd = fs.openSync(Anchored.child(next.parent.fd, next.name), O_RDONLY | O_DIRECTORY | O_NOFOLLOW); }
                    catch (error) {
                        cause(error);
                        if (error.code === "ELOOP") skipped.links++; else skipped.unreadable++;
                    } finally { release(next.parent); }
                    if (fd !== undefined) visit({ fd, refs: 1 }, next.path, next.depth);
                    // Yield between folders; one folder is the longest turn.
                    setImmediate(step);
                } catch (error) { end(error); }
            }
            try {
                visit({ fd: opened.fd, refs: 1 }, target.path, 0);
                setImmediate(step);
            } catch (error) { end(error); }
        });
    }

    function write(target, file, value) {
        const bytes = Buffer.from(value, "utf8");
        if (bytes.length > bounds.writeBytes)
            throw failed("The text is " + bytes.length + " bytes, over the " + bounds.writeBytes + " byte write ceiling.");
        return inParent(target.path, (parent, name) => {
            let mode = null;
            if (target.exists) {
                const stat = entry(parent, name);
                if (stat === null || stat.isSymbolicLink()) throw changed(target.path);
                if (!stat.isFile()) throw failed(target.path + " is " + described(stat) + "; files.write replaces regular files only.");
                mode = stat.mode & 0o777;
            }
            const temporary = ".jarvis-write-" + crypto.randomBytes(8).toString("hex");
            let fd, placed = false, note = "";
            try {
                fd = fs.openSync(Anchored.child(parent, temporary), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode === null ? 0o666 : 0o600);
                if (mode !== null) fs.fchmodSync(fd, mode);
                for (let written = 0; written < bytes.length;)
                    written += fs.writeSync(fd, bytes, written, bytes.length - written);
                fs.fsyncSync(fd);
                fs.closeSync(fd);
                fd = undefined;
                if (mode === null) {
                    // No replace: a file that appeared after the judge stays.
                    try { fs.linkSync(Anchored.child(parent, temporary), Anchored.child(parent, name)); }
                    catch (error) {
                        if (error.code === "EEXIST") throw failed(target.path + " appeared after the check; it was not replaced.");
                        throw error;
                    }
                } else {
                    const now = entry(parent, name);
                    if (now === null || !now.isFile()) throw changed(target.path);
                    fs.renameSync(Anchored.child(parent, temporary), Anchored.child(parent, name));
                }
                placed = true;
                fs.fsyncSync(parent);
            } catch (error) {
                if (error instanceof Ended) throw error;
                throw placed ? new Ended("unknown", target.path + " was written, but its folder could not be synced: " + cause(error) + ".")
                    : failed(target.path + " could not be written: " + cause(error) + ".");
            } finally {
                close(fd);
                if (mode === null || !placed) {
                    try { fs.unlinkSync(Anchored.child(parent, temporary)); }
                    catch (error) {
                        if (error.code !== "ENOENT") note = " The temporary file " + temporary + " could not be removed: " + cause(error) + ".";
                    }
                }
            }
            const result = readBack(parent, name, target.path, bytes, mode);
            return { outcome: result.outcome, content: result.content + note };
        }, () => failed("The folder of " + target.path + " does not exist; files.write creates no folders."));
    }

    // The written file, read again through the held folder.
    function readBack(parent, name, file, bytes, mode) {
        let fd;
        try {
            fd = fs.openSync(Anchored.child(parent, name), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
            const stat = fs.fstatSync(fd);
            const seen = stat.isFile() ? readBounded(fd, bounds.writeBytes, stat.size) : null;
            if (seen === null || !seen.equals(bytes) || (mode !== null && (stat.mode & 0o777) !== mode))
                return { outcome: "unknown", content: "The write finished, but " + file + " reads back different content or mode; another writer may have changed it." };
            const digest = crypto.createHash("sha256").update(seen).digest("hex").slice(0, 16);
            return { outcome: "completed", content: "Wrote " + file + ". Read back: " + seen.length + " bytes, sha256 " + digest
                + ", mode " + (stat.mode & 0o777).toString(8) + "." };
        } catch (error) {
            return { outcome: "unknown", content: "The write finished, but " + file + " could not be read back: " + cause(error) + "." };
        } finally { close(fd); }
    }

    function move(from, to, args) {
        if (!from.exists) throw failed(args.from + " does not exist.");
        if (from.path === to.path) throw failed(args.from + " and " + args.to + " are the same entry.");
        return inParent(from.path, (source, sourceName) => inParent(to.path, (folder, name) => {
            if (entry(source, sourceName) === null) throw changed(from.path);
            if (!to.exists && entry(folder, name) !== null)
                throw failed(to.path + " appeared after the check; it was not replaced.");
            try { fs.renameSync(Anchored.child(source, sourceName), Anchored.child(folder, name)); }
            catch (error) {
                if (error.code === "EXDEV") throw failed(from.path + " and " + to.path + " are on different file systems; files.move does not copy.");
                throw failed(from.path + " could not be moved: " + cause(error) + ".");
            }
            try {
                if (entry(source, sourceName) === null && entry(folder, name) !== null)
                    return { outcome: "completed", content: "Moved " + from.path + " to " + to.path + ". Read back: the source is absent and the destination is present." };
                return { outcome: "unknown", content: "The move finished, but the source or the destination reads back otherwise." };
            } catch (error) {
                if (!(error instanceof Ended)) throw error;
                return { outcome: "unknown", content: "The move finished, but it could not be read back: " + error.value.content };
            }
        }, () => failed("The folder of " + to.path + " does not exist; files.move creates no folders.")));
    }

    // Walk a whole tree before removing anything: every child is judged, and
    // any refusal, link swap or bound ends the call with nothing removed.
    function walk(parent, name, file, snapshot, depth, count) {
        if (depth > bounds.deleteDepth) throw failed(file + " is deeper than " + bounds.deleteDepth + " levels; nothing was removed.");
        const fd = openIn(parent, name, file, O_RDONLY | O_DIRECTORY);
        try {
            const stat = fs.fstatSync(fd);
            const node = { dev: stat.dev, ino: stat.ino, entries: [] };
            let names;
            try { names = fs.readdirSync(Anchored.child(fd, ".")); }
            catch (error) { throw failed(file + " could not be listed: " + cause(error) + "; nothing was removed."); }
            for (const child of names) {
                if (++count.value > bounds.deleteEntries)
                    throw failed(file + " holds more than " + bounds.deleteEntries + " entries; nothing was removed.");
                const childPath = path.join(file, child);
                const verdict = snapshot.inspect(childPath, "remove");
                if (verdict.kind !== "path") throw failed("Refused: " + verdict.reason + " for " + childPath + "; nothing was removed.");
                const childStat = entry(fd, child);
                if (childStat === null) throw changed(childPath);
                node.entries.push(childStat.isDirectory()
                    ? { name: child, node: walk(fd, child, childPath, snapshot, depth + 1, count) }
                    : { name: child, ino: childStat.ino });
            }
            return node;
        } finally { fs.closeSync(fd); }
    }

    // Remove bottom-up through held folders, matching each walked inode.
    function prune(parent, name, file, node, removed) {
        const fd = openIn(parent, name, file, O_RDONLY | O_DIRECTORY);
        try {
            const stat = fs.fstatSync(fd);
            if (stat.dev !== node.dev || stat.ino !== node.ino) throw changed(file);
            for (const item of node.entries) {
                if (item.node !== undefined) prune(fd, item.name, path.join(file, item.name), item.node, removed);
                else {
                    const now = entry(fd, item.name);
                    if (now === null || now.ino !== item.ino || now.isDirectory()) throw changed(path.join(file, item.name));
                    fs.unlinkSync(Anchored.child(fd, item.name));
                    removed.value++;
                }
            }
        } finally { fs.closeSync(fd); }
        fs.rmdirSync(Anchored.child(parent, name));
        removed.value++;
    }

    function remove(target, file, snapshot) {
        if (!target.exists) throw failed(file + " does not exist.");
        return inParent(target.path, (parent, name) => {
            const stat = entry(parent, name);
            if (stat === null) throw changed(target.path);
            const removed = { value: 0 };
            let total = 1;
            try {
                if (stat.isDirectory()) {
                    const count = { value: 0 };
                    const tree = walk(parent, name, target.path, snapshot, 0, count);
                    total += count.value;
                    prune(parent, name, target.path, tree, removed);
                } else {
                    // A link is removed itself, never its target.
                    fs.unlinkSync(Anchored.child(parent, name));
                    removed.value++;
                }
            } catch (error) {
                if (removed.value === 0) {
                    if (error instanceof Ended) throw error;
                    throw failed(target.path + " could not be removed: " + cause(error) + ".");
                }
                const reason = error instanceof Ended ? error.value.content : cause(error) + ".";
                throw failed("Removed " + removed.value + " of " + total + " entries under " + target.path + ", then stopped: " + reason);
            }
            let present;
            try { present = entry(parent, name) !== null; }
            catch (error) {
                if (!(error instanceof Ended)) throw error;
                return { outcome: "unknown", content: "The removal finished, but it could not be read back: " + error.value.content };
            }
            if (present) return { outcome: "unknown", content: "The removal finished, but " + target.path + " reads back present." };
            return { outcome: "completed", content: "Deleted " + target.path + " (" + removed.value + " entries). Read back: the path is absent." };
        });
    }

    // Changing acts stay synchronous: they run in the event-loop turn of the
    // router's rejudge and this executor's own.
    function act(call, targets, snapshot) {
        switch (call.id) {
        case "files.list": return list(targets.path, call.args.path);
        case "files.read": return read(targets.path, call.args.path);
        case "files.search": return search(targets.path, call.args.path, call.args.query, snapshot);
        case "files.write": return write(targets.path, call.args.path, call.args.text);
        case "files.move": return move(targets.from, targets.to, call.args);
        case "files.delete": return remove(targets.path, call.args.path, snapshot);
        default: throw new Error("jarvis: files=tool");
        }
    }

    function answer(error) {
        if (error instanceof Ended) return error.value;
        return { outcome: "failed", content: "files-executor-error" };
    }

    const record = {
        commands: [], cancellable: false,
        // The search is the longest path; every other act is synchronous.
        timeoutMs: bounds.searchMs + bounds.slackMs,
        start(call, done) {
            let result;
            try {
                if (closed) throw failed("The file tools are closed.");
                const refined = Tools.refine(call);
                if (refined.kind !== "call" || refined.executor !== "files") throw refused(refined.reason || "executor", call.id);
                let snapshot;
                try { snapshot = denied(); }
                catch (error) {
                    throw failed("The protected path list could not be built: "
                        + (error.code || String(error.message).replace(/[\x00-\x1f\x7f]/g, " ").slice(0, 120)) + ".");
                }
                const targets = {};
                for (const [field, role] of refined.paths) {
                    const verdict = snapshot.inspect(call.args[field], role);
                    if (verdict.kind !== "path") throw refused(verdict.reason, call.args[field]);
                    targets[field] = verdict;
                }
                result = act(refined.call, targets, snapshot);
            } catch (error) { result = answer(error); }
            if (result instanceof Promise) result.then(done, error => done(answer(error)));
            else done(result);
        }
    };

    // Lease loss: nothing starts after close, and a running search stops at
    // its next folder.
    return Object.freeze({ records: { files: Object.freeze(record) }, close() { closed = true; } });
}

/**
 * install({router, denied, bounds, clock}) registers the files executor at
 * once, since Node's fs needs no probe, but only when one Denied snapshot
 * builds. Without it the file tools stay unoffered, as a missing command's do.
 */
function install({ router, ...options }) {
    const files = create(options);
    try { options.denied(); }
    catch { return { close: files.close }; }
    router.register("files", files.records.files);
    return { close: files.close };
}

module.exports = { BOUNDS, create, install };
