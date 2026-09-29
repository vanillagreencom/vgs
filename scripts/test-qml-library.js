#!/usr/bin/env node
// Controls for bin/lib/qml-library.js, the loader every offline reader of the
// shell's libraries uses: a library loads with its functions callable, a
// library's `.import` of another library binds it under its qualifier, a
// file without the pragma is refused with its key and exit 2, and so are a
// file that cannot be read and an import the loader cannot resolve. Each row
// runs the loader in a child node so the exit status is the one a caller
// sees. Each mutation removes one rule from a copy of the loader and must
// turn the named row red.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const LOADER = path.join(__dirname, "..", "bin", "lib", "qml-library.js");
const ENV = { PATH: process.env.PATH, LC_ALL: "C" };

// Load FILE in a child through LOADER and print the JSON of `probe(library)`.
function loadIn(loader, file, probe) {
    const script = 'const l = require(process.argv[1]).load(process.argv[2]); process.stdout.write(JSON.stringify((' + probe + ')(l)));';
    return spawnSync(process.execPath, ["-e", script, loader, file], { encoding: "utf8", env: ENV });
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "qml-library-"));
function write(name, text) {
    const file = path.join(tmp, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text);
    return file;
}

// Rows: name and a function of the loader answering [ok, detail].
function rows() {
    const good = write("good.js", ".pragma library\nvar ANSWER = 42;\nfunction twice(n) { return n * 2; }\n");
    const bare = write("bare.js", "var ANSWER = 42;\n");
    const commented = write("commented.js", "// a note first\n.pragma library\nvar ANSWER = 42;\n");
    const absent = path.join(tmp, "absent.js");
    write("lib/Names.js", ".pragma library\nvar NAMES = { a: 1 };\n");
    const importer = write("importer.js", ".pragma library\n.import \"lib/Names.js\" as Names\nfunction known(n) { return Object.prototype.hasOwnProperty.call(Names.NAMES, n); }\n");
    const importsBare = write("imports-bare.js", ".pragma library\n.import \"bare.js\" as Bare\nvar X = 1;\n");
    const moduleImport = write("module-import.js", ".pragma library\n.import QtQuick 2.0 as Q\nvar X = 1;\n");
    const lateImport = write("late-import.js", ".pragma library\nvar X = 1;\n.import \"good.js\" as Good\n");
    const said = r => `exit=${r.status} stdout=${r.stdout} stderr=${r.stderr}`;
    const out = [
        ["a library loads with its variables and functions", loader => { const r = loadIn(loader, good, "l => [l.ANSWER, l.twice(21)]"); return [r.status === 0 && r.stdout === "[42,42]", said(r)]; }],
        ["a file without the pragma is refused with its key", loader => { const r = loadIn(loader, bare, "l => l.ANSWER"); return [r.status === 2 && r.stderr === "qml-library: refused: pragma=missing path=" + bare + "\n" && r.stdout === "", said(r)]; }],
        ["a pragma that is not the first line is refused", loader => { const r = loadIn(loader, commented, "l => l.ANSWER"); return [r.status === 2 && r.stderr.startsWith("qml-library: refused: pragma=missing path="), said(r)]; }],
        ["a file that cannot be read is refused with its key", loader => { const r = loadIn(loader, absent, "l => l.ANSWER"); return [r.status === 2 && r.stderr === "qml-library: refused: unreadable path=" + absent + " error=ENOENT\n", said(r)]; }],
        ["an imported library is bound under its qualifier, its path relative to the importer", loader => { const r = loadIn(loader, importer, "l => [l.known('a'), l.known('b')]"); return [r.status === 0 && r.stdout === "[true,false]", said(r)]; }],
        ["an imported file without the pragma is refused", loader => { const r = loadIn(loader, importsBare, "l => l.X"); return [r.status === 2 && r.stderr === "qml-library: refused: pragma=missing path=" + path.join(tmp, "bare.js") + "\n", said(r)]; }],
        ["a module import is refused with its key", loader => { const r = loadIn(loader, moduleImport, "l => l.X"); return [r.status === 2 && r.stderr === "qml-library: refused: import=\".import QtQuick 2.0 as Q\" path=" + moduleImport + "\n", said(r)]; }],
        ["an import after the header is refused with its key", loader => { const r = loadIn(loader, lateImport, "l => l.X"); return [r.status === 2 && r.stderr.startsWith("qml-library: refused: import="), said(r)]; }],
    ];
    for (const lib of ["PluginLogic.js", "Dispatch.js"]) {
        const file = path.join(__dirname, "..", "shell", "Core", lib);
        out.push(["the shell's " + lib + " loads", loader => { const r = loadIn(loader, file, "l => typeof l." + (lib === "Dispatch.js" ? "request" : "validateManifest")); return [r.status === 0 && r.stdout === '"function"', said(r)]; }]);
    }
    return out;
}

// Mutations: label, the text in the loader, its replacement, and the row
// that must go red. The replacement keeps the text and removes the rule.
const MUTATIONS = [
    ["the import is not bound", "library[m[2]] = load(path.resolve(path.dirname(file), m[1]));", "load(path.resolve(path.dirname(file), m[1]));", "an imported library is bound under its qualifier, its path relative to the importer"],
    ["the import resolves from the working directory", "path.resolve(path.dirname(file), m[1])", "path.resolve(m[1])", "an imported library is bound under its qualifier, its path relative to the importer"],
    ["a module import is carried", "if (m === null || !header) refuse(", "if (false) refuse(", "a module import is refused with its key"],
    ["an import after the header is carried", "if (m === null || !header) refuse(", "if (m === null) refuse(", "an import after the header is refused with its key"],
];

let failures = 0;
function check(name, ok, detail) {
    console.log((ok ? "  ok    " : "  FAIL  ") + name + (ok ? "" : "\n        " + detail));
    if (!ok) failures += 1;
}

try {
    const table = rows();
    for (const [name, run] of table) {
        const [ok, detail] = run(LOADER);
        check(name, ok, detail);
    }
    const shipped = fs.readFileSync(LOADER, "utf8");
    for (const [label, needle, replacement, rowName] of MUTATIONS) {
        const count = shipped.split(needle).length - 1;
        if (count !== 1) { check("control: " + label, false, "the needle matches " + count + " times"); continue; }
        const copy = path.join(tmp, "mutant-qml-library.js");
        fs.writeFileSync(copy, shipped.replace(needle, replacement));
        const row = table.find(([name]) => name === rowName);
        const [ok] = row[1](copy);
        check("control: " + label + " turns red: " + rowName, !ok, "the row passed on the mutant");
    }
} finally {
    fs.rmSync(tmp, { recursive: true, force: true });
}

if (failures > 0) { console.log("test-qml-library: failed=" + failures); process.exit(1); }
console.log("test-qml-library: ok");
