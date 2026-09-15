// Load a shipped `.pragma library` QML script as a node module.
//
// These files are plain JavaScript wrapped in two QML-only directives: `.pragma
// library` and `.import "./Other.js" as Name`. Neither parses in node, so both are
// removed and each import is supplied as an argument, which is what lets a test run
// the code the shell runs instead of a copy of it.

"use strict";

const fs = require("node:fs");
const path = require("node:path");

const VSHELL = path.join(__dirname, "..", "..", "quickshell", "vshell");

const PRAGMA_RE = /^\s*\.pragma\s+library\s*$/gm;
const IMPORT_RE = /^\s*\.import\s+"([^"]+)"\s+as\s+([A-Za-z_$][\w$]*)\s*$/gm;

/**
 * Load the library at `rel` (relative to quickshell/vshell) and return the named
 * top-level functions and variables.
 *
 * Imports are resolved by reading the imported file the same way, so a library's
 * own dependency is the shipped one rather than a stub.
 *
 * @param {string} rel     path under quickshell/vshell, e.g. "Common/settings/SessionStore.js"
 * @param {string[]} names top-level names to return
 * @returns {Object} the named values
 */
function loadLibrary(rel, names) {
    const source = fs.readFileSync(path.join(VSHELL, rel), "utf8");
    const imports = [...source.matchAll(IMPORT_RE)];
    const body = source.replace(PRAGMA_RE, "").replace(IMPORT_RE, "");
    const modules = imports.map(([, target, alias]) => ({
        alias,
        value: loadLibraryFile(path.resolve(path.dirname(path.join(VSHELL, rel)), target))
    }));
    // eslint-disable-next-line no-new-func
    const make = new Function(...modules.map(m => m.alias), `${body}\nreturn { ${names.join(", ")} };`);
    return make(...modules.map(m => m.value));
}

// An imported library's whole top level, since the importer names members at use time.
function loadLibraryFile(file) {
    const source = fs.readFileSync(file, "utf8");
    const body = source.replace(PRAGMA_RE, "").replace(IMPORT_RE, "");
    const declared = [...body.matchAll(/^(?:function|var|const|let)\s+([A-Za-z_$][\w$]*)/gm)].map(m => m[1]);
    // eslint-disable-next-line no-new-func
    return new Function(`${body}\nreturn { ${[...new Set(declared)].join(", ")} };`)();
}

module.exports = { loadLibrary };
