#!/usr/bin/env node
// Controls for scripts/qml-library.js, the loader every offline reader of the
// shell's libraries uses: a library loads with its functions callable, a file
// without the pragma is refused with its key and exit 2, and so is a file that
// cannot be read. Each row runs the loader in a child node so the exit status
// is the one a caller sees.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const LOADER = path.join(__dirname, "qml-library.js");
const ENV = { PATH: process.env.PATH, LC_ALL: "C" };

let failures = 0;
function check(name, ok, detail) {
    console.log((ok ? "  ok    " : "  FAIL  ") + name + (ok ? "" : "\n        " + detail));
    if (!ok) failures += 1;
}

// Load FILE in a child and print the JSON of `probe(library)`.
function loadIn(file, probe) {
    const script = 'const l = require(process.argv[1]).load(process.argv[2]); process.stdout.write(JSON.stringify((' + probe + ')(l)));';
    return spawnSync(process.execPath, ["-e", script, LOADER, file], { encoding: "utf8", env: ENV });
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "qml-library-"));
try {
    const good = path.join(tmp, "good.js");
    fs.writeFileSync(good, ".pragma library\nvar ANSWER = 42;\nfunction twice(n) { return n * 2; }\n");
    let r = loadIn(good, "l => [l.ANSWER, l.twice(21)]");
    check("a library loads with its variables and functions", r.status === 0 && r.stdout === "[42,42]", `exit=${r.status} stdout=${r.stdout} stderr=${r.stderr}`);

    const bare = path.join(tmp, "bare.js");
    fs.writeFileSync(bare, "var ANSWER = 42;\n");
    r = loadIn(bare, "l => l.ANSWER");
    check("a file without the pragma is refused with its key", r.status === 2 && r.stderr === "qml-library: refused: pragma=missing path=" + bare + "\n" && r.stdout === "", `exit=${r.status} stdout=${r.stdout} stderr=${r.stderr}`);

    const commented = path.join(tmp, "commented.js");
    fs.writeFileSync(commented, "// a note first\n.pragma library\nvar ANSWER = 42;\n");
    r = loadIn(commented, "l => l.ANSWER");
    check("a pragma that is not the first line is refused", r.status === 2 && r.stderr.startsWith("qml-library: refused: pragma=missing path="), `exit=${r.status} stderr=${r.stderr}`);

    const absent = path.join(tmp, "absent.js");
    r = loadIn(absent, "l => l.ANSWER");
    check("a file that cannot be read is refused with its key", r.status === 2 && r.stderr === "qml-library: refused: unreadable path=" + absent + " error=ENOENT\n", `exit=${r.status} stderr=${r.stderr}`);

    for (const lib of ["PluginLogic.js", "Dispatch.js"]) {
        const file = path.join(__dirname, "..", "shell", "Core", lib);
        r = loadIn(file, "l => typeof l." + (lib === "Dispatch.js" ? "request" : "validateManifest"));
        check("the shell's " + lib + " loads", r.status === 0 && r.stdout === '"function"', `exit=${r.status} stdout=${r.stdout} stderr=${r.stderr}`);
    }
} finally {
    fs.rmSync(tmp, { recursive: true, force: true });
}

if (failures > 0) { console.log("test-qml-library: failed=" + failures); process.exit(1); }
console.log("test-qml-library: ok");
