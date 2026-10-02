// The one anchored descriptor walk for account discovery and the file tools.
// Linux /proc/self/fd/<fd>/<name> paths resolve through a held directory's
// inode, so a component renamed or swapped for a link after a judge is
// refused or stays inside that directory; it is never followed elsewhere.
"use strict";
const fs = require("node:fs");
const { O_RDONLY, O_DIRECTORY, O_NOFOLLOW } = fs.constants;

/** The path of `name` inside the directory held open as `fd`. */
function child(fd, name) {
    return "/proc/self/fd/" + fd + "/" + name;
}

/**
 * Open every component of an absolute normal path as a directory from "/",
 * holding each parent while its child opens. The only link followed is our
 * own /proc descriptor. Returns {kind: "directory", fd}, whose fd the caller
 * closes, or one of {kind: "absent"}, {kind: "unreadable", code},
 * {kind: "link"}, {kind: "not-directory"} and {kind: "unreadable-or-changed"}.
 */
function directory(file) {
    let fd = fs.openSync("/", O_RDONLY | O_DIRECTORY);
    try {
        for (const part of file.split("/").filter(Boolean)) {
            let stat;
            try { stat = fs.lstatSync(child(fd, part)); }
            catch (error) { return error.code === "ENOENT" ? { kind: "absent" } : { kind: "unreadable", code: error.code }; }
            if (stat.isSymbolicLink()) return { kind: "link" };
            if (!stat.isDirectory()) return { kind: "not-directory" };
            let next;
            try { next = fs.openSync(child(fd, part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW); }
            catch { return { kind: "unreadable-or-changed" }; }
            fs.closeSync(fd);
            fd = next;
        }
        const result = { kind: "directory", fd };
        fd = undefined;
        return result;
    } finally { if (fd !== undefined) fs.closeSync(fd); }
}

module.exports = { child, directory };
