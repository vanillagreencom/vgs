#!/usr/bin/env node
// Stand-in `claude` for coding-task suites. Source: the Claude Code hooks
// reference, code.claude.com/docs/en/hooks, and CLI reference --settings,
// fetched 2026-10-02. No vendor program, login, network or recording.
//
// argv: --settings JSON -- PROMPT, exactly; anything else exits 64. It runs the
// steps in $CLAUDE_CONFIG_DIR/script.json, in order, after it appends
// {start: {settings, env}} to $CLAUDE_CONFIG_DIR/log.jsonl:
//   {hook: EVENT, input: {...}}  runs every command hook settings wire for
//       EVENT, as Claude Code does: stdin is the common input fields plus
//       hook_event_name and input; exec form (command spawned with args, no
//       shell) when args is set, else `sh -c command`; ended with SIGTERM
//       past its timeout in seconds. Each run appends {event, status,
//       signal, stdout, stderr} to $CLAUDE_CONFIG_DIR/log.jsonl.
//   {report: "reported-ok" | "reported-failed"}  runs the matching command
//       the brief in PROMPT prints, as an agent following it would.
//   {gate: NAME}  waits until $CLAUDE_CONFIG_DIR/NAME exists.
// Then it exits 0.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");

function refuse(reason) {
    process.stderr.write("claude-stub: " + reason + "\n");
    process.exit(64);
}

const args = process.argv.slice(2);
if (args.length !== 4 || args[0] !== "--settings" || args[2] !== "--") refuse("argv");
let settings;
try { settings = JSON.parse(args[1]); } catch { refuse("settings-json"); }
const prompt = args[3];
const home = process.env.CLAUDE_CONFIG_DIR;
if (typeof home !== "string" || !path.isAbsolute(home)) refuse("config-dir");
const script = JSON.parse(fs.readFileSync(path.join(home, "script.json"), "utf8"));
const log = entry => fs.appendFileSync(path.join(home, "log.jsonl"), JSON.stringify(entry) + "\n");
log({ start: { settings, env: process.env } });

function run(event, input) {
    const groups = settings.hooks?.[event] ?? [];
    for (const group of groups) {
        for (const hook of group.hooks) {
            if (hook.type !== "command") refuse("hook-type");
            const body = JSON.stringify({ session_id: "stub-session", transcript_path: path.join(home, "transcript.jsonl"),
                cwd: process.cwd(), permission_mode: "default", hook_event_name: event, ...input });
            const options = { input: body, encoding: "utf8", env: process.env, killSignal: "SIGTERM",
                timeout: (hook.timeout ?? 600) * 1000 };
            const result = Array.isArray(hook.args) ? cp.spawnSync(hook.command, hook.args, options)
                : cp.spawnSync("sh", ["-c", hook.command], options);
            log({ event, status: result.status, signal: result.signal, stdout: result.stdout ?? "", stderr: result.stderr ?? "" });
        }
    }
}

for (const step of script) {
    if (step.hook !== undefined) run(step.hook, step.input ?? {});
    else if (step.report !== undefined) {
        const prefix = step.report === "reported-ok" ? "- if the task succeeded: " : "- if the task failed: ";
        const line = prompt.split("\n").find(item => item.startsWith(prefix));
        if (line === undefined) refuse("report-line");
        cp.execFileSync("sh", ["-c", line.slice(prefix.length)], { stdio: "inherit" });
    } else if (step.gate !== undefined) {
        while (!fs.existsSync(path.join(home, step.gate))) cp.execFileSync("sleep", ["0.05"]);
    } else refuse("step");
}
