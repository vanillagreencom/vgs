// The private-directory helper the audit store and the tool bridge's runtime
// directory share.
"use strict";
const fs = require("node:fs");
const path = require("node:path");

function fail(code) {
    const error = new Error("jarvis: private=" + code);
    error.code = code;
    throw error;
}

/**
 * Create an absolute directory and every missing parent with mode 0700, refuse
 * a link or non-directory anywhere in the path and a leaf another user owns,
 * then set the leaf to 0700. Paths come from the shell's trusted XDG snapshot;
 * the whole path is checked rather than writing through a configured alias.
 * Errors carry a keyed code: directory-type, directory-owner or the fs code.
 */
function directory(target) {
    let current = "/";
    for (const component of target.split("/").filter(Boolean)) {
        current = path.join(current, component);
        try { fs.mkdirSync(current, { mode: 0o700 }); }
        catch (error) { if (error.code !== "EEXIST") throw error; }
        if (!fs.lstatSync(current).isDirectory()) fail("directory-type");
    }
    if (fs.lstatSync(target).uid !== process.getuid()) fail("directory-owner");
    fs.chmodSync(target, 0o700);
}

module.exports = { directory };
