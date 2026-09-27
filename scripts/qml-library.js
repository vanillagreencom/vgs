// Load one of the shell's `.pragma library` JavaScript files under node, so a
// script makes its decision through the shell's own judge instead of a copy.
// Every offline reader of shell/Core/PluginLogic.js and shell/Core/Dispatch.js
// goes through here: scripts/check-manifests.js, bin/vgsh-plugin-judge,
// scripts/test-plugin-logic.js and scripts/test-dispatch.js.
//
// The pragma is what marks a file as a library Quickshell shares between QML
// files; a file without it is not one the shell loads that way, so loading it
// here would judge with code the shell never runs. Such a file is refused
// with one keyed line on stderr and exit 2, as is a file that cannot be read:
//   qml-library: refused: pragma=missing path=<file>
//   qml-library: refused: unreadable path=<file> error=<code>
"use strict";
const fs = require("fs");
const vm = require("vm");

const PRAGMA = ".pragma library\n";

function refuse(first) {
    process.stderr.write("qml-library: refused: " + first + "\n");
    process.exit(2);
}

// The library's top-level functions and variables as properties of one
// object, evaluated in a fresh context with no access to this process.
function load(file) {
    let source;
    try {
        source = fs.readFileSync(file, "utf8");
    } catch (e) {
        refuse("unreadable path=" + file + " error=" + e.code);
    }
    if (!source.startsWith(PRAGMA)) refuse("pragma=missing path=" + file);
    const library = {};
    vm.runInNewContext(source.slice(PRAGMA.length), library, { filename: file });
    return library;
}

module.exports = { load };
