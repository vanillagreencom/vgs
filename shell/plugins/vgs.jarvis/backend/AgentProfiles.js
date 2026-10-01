// Coding-agent profile rows: the program, its argv, the account variable and
// the interrupt one agent takes. The Claude Code and Codex issues add rows,
// with the hook wiring their own contract defines; production ships none.
// The goal brief and the scrubbed environment every agent receives are built
// here once. TaskRunner.js consumes this module; nothing here starts a process.
"use strict";
const path = require("node:path");

const SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"];
// Spec env keys an agent receives from the daemon's own environment. The
// launcher adds only TERM and COLORTERM from its terminal.
const BASE_ENV = ["PATH", "HOME", "LANG", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
    "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"];
const RESERVED_ENV = BASE_ENV.concat(["TERM", "COLORTERM"]);
const MAX_ARGS = 64;

function fail(reason) {
    throw new Error("jarvis: profiles=" + reason);
}

function shape(value, fields) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
        && Object.keys(value).sort().join(",") === fields.slice().sort().join(",");
}

function absolute(value) {
    return typeof value === "string" && path.isAbsolute(value) && !/[\x00-\x1f\x7f]/.test(value);
}

/**
 * A row is { program, argv(task) -> string[], account: { variable } | null,
 * interrupt: { signal }, interruptMs }. program is the bare command the
 * agent's argv starts with; argv receives { brief, cwd, account }.
 */
function row(id, value) {
    if (!/^[a-z][a-z0-9-]{0,31}$/.test(id)) fail("id value=" + id);
    if (!shape(value, ["program", "argv", "account", "interrupt", "interruptMs"])
            || typeof value.program !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$/.test(value.program)
            || typeof value.argv !== "function"
            || (value.account !== null && (!shape(value.account, ["variable"])
                || typeof value.account.variable !== "string" || !/^[A-Z_][A-Z0-9_]{0,63}$/.test(value.account.variable)
                || RESERVED_ENV.includes(value.account.variable)))
            || !shape(value.interrupt, ["signal"]) || !SIGNALS.includes(value.interrupt.signal)
            || !Number.isSafeInteger(value.interruptMs) || value.interruptMs < 100 || value.interruptMs > 60000)
        fail("row id=" + id);
    return Object.freeze({ ...value, account: value.account === null ? null : Object.freeze({ ...value.account }),
        interrupt: Object.freeze({ ...value.interrupt }) });
}

/** Validate a whole table; a defect throws when the table is built. */
function table(rows) {
    const out = {};
    for (const [id, value] of Object.entries(rows)) out[id] = row(id, value);
    return Object.freeze(out);
}

const TABLE = table({});

/** Rows whose program lookup(program) finds, in table order, as { id, row }. */
function available(lookup, profiles = TABLE) {
    return Object.entries(profiles).filter(([, value]) => lookup(value.program)).map(([id, value]) => ({ id, row: value }));
}

// POSIX single quotes: the only character to escape is the quote itself.
function quote(text) {
    return "'" + text.replace(/'/g, "'\\''") + "'";
}

/**
 * The text every agent receives: the user's goal, then a last step that
 * reports the outcome through the task's recorded producer. The goal is
 * data inside the brief, never shell code; only the report commands are.
 */
function brief({ goal, engine, state, id }) {
    if (typeof goal !== "string" || goal.length === 0 || !absolute(engine) || !absolute(state)
            || typeof id !== "string" || !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(id)) fail("brief");
    const report = kind => "printf '%s' " + quote(JSON.stringify({ kind })) + " | node "
        + [engine, "--state", state, id, "outcome"].map(quote).join(" ");
    return goal + "\n\nAs your last step, report the outcome of this task by running exactly one of these commands:\n"
        + "- if the task succeeded: " + report("reported-ok") + "\n"
        + "- if the task failed: " + report("reported-failed") + "\n";
}

/** The agent's argv for one task, starting with the row's program. */
function command(value, task) {
    const argv = value.argv(task);
    if (!Array.isArray(argv) || argv.length < 1 || argv.length > MAX_ARGS || argv[0] !== value.program
            || !argv.every(arg => typeof arg === "string" && arg.length > 0 && !arg.includes("\0")))
        fail("argv program=" + value.program);
    return argv.slice();
}

/** The base keys present in source: what the terminal's server receives. */
function base(source) {
    const env = {};
    for (const key of BASE_ENV)
        if (typeof source[key] === "string" && source[key] !== "" && !source[key].includes("\0")) env[key] = source[key];
    return env;
}

/** The agent's explicit environment: base(source), plus the account
 * variable when an account is selected. */
function environment(value, account, source) {
    const env = base(source);
    if (account !== "") {
        if (value.account === null) fail("account-unsupported program=" + value.program);
        env[value.account.variable] = account;
    }
    return env;
}

module.exports = { TABLE, table, available, brief, command, base, environment };
