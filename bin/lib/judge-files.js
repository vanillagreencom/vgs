// The file helpers and the refusal bin/vgsh-plugin-judge and
// bin/vgsh-theme-judge share, so both write a watched file the same way and
// refuse with the same line.
//
// A refusal is one line on stderr, `vgsh: refused: <first>`, and the exit
// status the refusal carries, 1 unless it names another. A helper throws it
// and `main` prints it, so a caller can put its own output ahead of the line
// (a structured result) or undo a half-made change on the way out.
"use strict";
const fs = require("fs");
const path = require("path");

class Refusal extends Error {
    // FIRST is the keyed line after `vgsh: refused: `; REASON the value of
    // its key, for a caller that reports it in a structured result.
    constructor(first, reason, status = 1) {
        super(first);
        this.first = first;
        this.reason = reason;
        this.status = status;
    }
}

function refuse(first, reason, status) {
    throw new Refusal(first, reason, status);
}

// Run a judge's command; a Refusal ends the process with its line and status.
function main(command) {
    try {
        command();
    } catch (e) {
        if (!(e instanceof Refusal)) throw e;
        process.stderr.write("vgsh: refused: " + e.first + "\n");
        process.exit(e.status);
    }
}

// The parsed JSON file. KEY leads the refusal line:
// `KEY=unreadable path=<file> error=<code>` or `KEY=unparseable path=<file>`.
function readJson(file, key) {
    let text;
    try {
        text = fs.readFileSync(file, "utf8");
    } catch (e) {
        refuse(key + "=unreadable path=" + file + " error=" + e.code, "unreadable");
    }
    try {
        return JSON.parse(text);
    } catch (e) {
        refuse(key + "=unparseable path=" + file, "unparseable");
    }
}

// Replace a file by rename, so a shell watching it never reads half of it.
// DATA is a string or a Buffer, written as it is. KEY leads the refusal
// line: `KEY=unwritable path=<file> error=<code>`.
function replaceFile(file, data, key) {
    const tmp = file + ".vgsh-" + process.pid;
    try {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(tmp, data);
        fs.renameSync(tmp, file);
    } catch (e) {
        fs.rmSync(tmp, { force: true });
        refuse(key + "=unwritable path=" + file + " error=" + e.code, "unwritable");
    }
}

module.exports = { Refusal, refuse, main, readJson, replaceFile };
