// The file helpers and the refusal bin/vgsh-plugin-judge,
// bin/vgsh-theme-judge, bin/vgsh-hypr-judge, bin/vgsh-pkg and the
// vgs.devtools engine share, so each writes a watched file the same way,
// finds a command on PATH the same way, keeps a change to the system in
// the user's terminal the same way and refuses with the same line.
//
// A refusal is one line on stderr, `vgsh: refused: <first>`, then its
// detail, the English or a tool's own words, when it carries one, and the
// exit status the refusal carries, 1 unless it names another. A helper throws it
// and `main` prints it, so a caller can put its own output ahead of the line
// (a structured result) or undo a half-made change on the way out.
"use strict";
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

class Refusal extends Error {
    // FIRST is the keyed line after `vgsh: refused: `; REASON the value of
    // its key, for a caller that reports it in a structured result; DETAIL
    // the text printed after the line, "" for none.
    constructor(first, reason, status = 1, detail = "") {
        super(first);
        this.first = first;
        this.reason = reason;
        this.status = status;
        this.detail = detail;
    }
}

function refuse(first, reason, status, detail) {
    throw new Refusal(first, reason, status, detail);
}

// Run a judge's command; a Refusal ends the process with its line, its
// detail and its status. A command that returns a promise ends the same way
// when the promise rejects with a Refusal. NAME leads the line: `vgsh` for
// the core's commands, a plugin program's own name for one that shares
// these helpers.
function main(command, name = "vgsh") {
    const end = e => {
        if (!(e instanceof Refusal)) throw e;
        const detail = e.detail === "" || e.detail.endsWith("\n") ? e.detail : e.detail + "\n";
        process.stderr.write(name + ": refused: " + e.first + "\n" + detail);
        process.exit(e.status);
    };
    let result;
    try {
        result = command();
    } catch (e) {
        end(e);
    }
    if (result !== undefined && typeof result.then === "function") result.catch(end);
}

// The parsed JSON file. KEY leads the refusal line:
// `KEY=unreadable path=<file> error=<code>` or `KEY=unparseable path=<file>`.
// With OPTIONAL an absent file answers null instead of the refusal.
function readJson(file, key, optional = false) {
    let text;
    try {
        text = fs.readFileSync(file, "utf8");
    } catch (e) {
        if (optional && e.code === "ENOENT") return null;
        refuse(key + "=unreadable path=" + file + " error=" + e.code, "unreadable");
    }
    try {
        return JSON.parse(text);
    } catch (e) {
        refuse(key + "=unparseable path=" + file, "unparseable");
    }
}

// A shell.json layer read and judged by PluginLogic.configError, LOGIC here,
// the judge Config.qml runs on every parse, so a judge and the shell agree on
// which files hold a configuration and which are malformed: the refusal
// `KEY=malformed path=<file> error=<defect>`. With OPTIONAL an absent file
// answers null.
function readConfig(logic, file, key, optional = false) {
    const config = readJson(file, key, optional);
    if (config === null && optional) return null;
    const error = logic.configError(config);
    if (error !== "") refuse(key + "=malformed path=" + file + " error=" + error, "malformed");
    return config;
}

// Run WRITE, a change to FILE through fs calls; a failed call is the
// refusal `KEY=unwritable path=<file> error=<code>`.
function writing(file, key, write) {
    try {
        write();
    } catch (e) {
        refuse(key + "=unwritable path=" + file + " error=" + e.code, "unwritable");
    }
}

// Replace a file by rename, so a shell watching it never reads half of it.
// DATA is a string or a Buffer, written as it is; MODE, when given, is the
// permission bits the new file takes. With a MODE the file kept may be
// private, such as a CLI's settings holding credentials, so the staging copy
// is created afresh and owner-only before any byte is written, and takes
// MODE only once it holds DATA. A failure leaves no temporary file and
// refuses as `writing` does.
function replaceFile(file, data, key, mode) {
    const tmp = file + ".vgsh-" + process.pid;
    writing(file, key, () => {
        try {
            fs.mkdirSync(path.dirname(file), { recursive: true });
            if (mode === undefined) {
                fs.writeFileSync(tmp, data);
            } else {
                fs.rmSync(tmp, { force: true });
                fs.writeFileSync(tmp, data, { flag: "wx", mode: 0o600 });
                fs.chmodSync(tmp, mode);
            }
            fs.renameSync(tmp, file);
        } catch (e) {
            fs.rmSync(tmp, { force: true });
            throw e;
        }
    });
}

// Take flock on FILE, made with its directory when absent: { state: "held",
// release() } once this process holds it, which its exit frees too;
// { state: "busy" } when another process holds it and WAIT is false, or a
// number of seconds that passed while it waited; WAIT true waits unbounded;
// { state: "failed", error } with the error code, or `status=<n>` for a
// flock(1) that exited otherwise. flock(1) locks the descriptor it inherits
// as its fd 3, and a flock lock belongs to the open file description, which
// this process keeps open after the child exits, so the lock stays held
// here. Node opens every file close-on-exec, so no process this one starts
// holds it.
function lockFile(file, wait) {
    let fd;
    try {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fd = fs.openSync(file, "a");
    } catch (e) {
        return { state: "failed", error: e.code };
    }
    const args = wait === true ? ["3"] : wait === false ? ["-n", "-E", "75", "3"] : ["-w", String(wait), "-E", "75", "3"];
    const taken = spawnSync("flock", args, { stdio: ["ignore", "ignore", "ignore", fd] });
    if (taken.status === 0) return { state: "held", release() { fs.closeSync(fd); } };
    fs.closeSync(fd);
    if (wait !== true && taken.status === 75) return { state: "busy" };
    return { state: "failed", error: taken.error !== undefined ? taken.error.code : "status=" + taken.status };
}

// Edit the file FILE where it stands: a symlink is resolved and the file it
// names is replaced with its mode kept, so a dotfile manager's link stays a
// link. EDIT maps the file's text, or undefined for an absent file, to the
// new text, null to leave the file as it is, or a refusal, which fails the
// target and leaves the file. The bytes are read and written as latin1, one
// character per byte, so every byte EDIT keeps is kept. An absent file EDIT
// does not refuse is created only when CREATE is true, and never through a
// dangling symlink. Answers null, or the failure's { reason, failure }, its
// line led by KEY. A theme target's include line and the Hyprland layer's
// line (bin/vgsh-hypr-judge) are both kept through here.
function editFile(key, file, create, edit) {
    let real = null;
    let text;
    try {
        real = fs.realpathSync(file);
        text = fs.readFileSync(real, "latin1");
    } catch (e) {
        if (e.code !== "ENOENT") return { reason: "unreadable", failure: key + "=unreadable path=" + file + " error=" + e.code };
        real = null;
    }
    const next = edit(text);
    if (next === null) return null;
    if (typeof next !== "string") return { reason: next.reason, failure: key + "=" + next.reason + " path=" + file + (next.detail === "" ? "" : " " + next.detail) };
    if (real === null && !create) return { reason: "wiring-file-absent", failure: key + "=wiring-file-absent path=" + file };
    try {
        if (real === null) {
            writing(file, key, () => {
                fs.mkdirSync(path.dirname(file), { recursive: true });
                fs.writeFileSync(file, Buffer.from(next, "latin1"), { flag: "wx" });
            });
        } else {
            let mode;
            writing(real, key, () => { mode = fs.statSync(real).mode & 0o7777; });
            replaceFile(real, Buffer.from(next, "latin1"), key, mode);
        }
    } catch (e) {
        if (!(e instanceof Refusal)) throw e;
        return { reason: e.reason, failure: e.first };
    }
    return null;
}

// Whether COMMAND is an executable file in an absolute directory of PATH. A
// relative entry names no fixed directory and is skipped; a directory that
// cannot be searched holds no command, as it holds none for a shell.
function onPath(command) {
    for (const dir of (process.env.PATH || "").split(path.delimiter)) {
        if (!path.isAbsolute(dir)) continue;
        const file = path.join(dir, command);
        try {
            fs.accessSync(file, fs.constants.X_OK);
            if (fs.statSync(file).isFile()) return true;
        } catch (e) {
            if (!["ENOENT", "ENOTDIR", "EACCES"].includes(e.code)) throw e;
        }
    }
    return false;
}

// A change to the user's system runs only where its user sees and answers
// the prompt: never in a process the shell started, and never without a
// terminal. `vgsh run` exports VGSH_RUNNER_PID to the shell and so to every
// process the shell starts, apart from the programs it opens for the user
// (shell.run.detached and a floating TUI's terminal). Refuses
// `caller=shell verb=<verb>` with SHELL_DETAIL, which names where the
// change runs instead, or `<verb>=no-terminal`. Checked before any query,
// plan or step.
function refuseOutsideTerminal(verb, shellDetail) {
    if (process.env.VGSH_RUNNER_PID !== undefined)
        refuse("caller=shell verb=" + verb, undefined, 1, shellDetail);
    try {
        fs.closeSync(fs.openSync("/dev/tty", "r+"));
    } catch (e) {
        refuse(verb + "=no-terminal", undefined, 1, "/dev/tty did not open (" + e.code + "); run this in a terminal, where the password prompt shows");
    }
}

// One word as a POSIX shell reads it back: single-quoted, each quote
// closed, escaped and reopened.
function shellWord(word) {
    return "'" + word.replace(/'/g, "'\\''") + "'";
}

module.exports = { Refusal, refuse, main, readJson, readConfig, writing, replaceFile, lockFile, editFile, onPath, refuseOutsideTerminal, shellWord };
