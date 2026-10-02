# Jarvis Claude Code task profile

Covers: shell/plugins/vgs.jarvis/backend/AgentProfiles.js, shell/plugins/vgs.jarvis/backend/claude-hook, shell/plugins/vgs.jarvis/backend/TaskRelay.js, scripts/test-jarvis-claude-task.js, scripts/fixtures/jarvis-claude/claude-task.js

This page holds how Jarvis runs Claude Code as a coding agent: its profile row, the hooks it passes, and the relay that carries a permission request or a question to the user and the answer back. [jarvis-task-control.md](jarvis-task-control.md) owns launch, identity, stop and display. [jarvis-tasks.md](jarvis-tasks.md) owns the records the hooks write. [D072](../decisions/D072-coding-task-records-and-four-fact-state.md) gives profiles the vendor hook translation and the prompt responses. The [Jarvis plan § Coding-task delegation](../plans/v2-jarvis-plan.md#7-coding-task-delegation) sets the scope.

A coding task is a handoff, not a brain. Claude Code runs interactively in the task's terminal under the user's own permission mode and rules; Jarvis passes no permission flag. The [Claude Code harness](jarvis-claude.md) is the other use of the same program: a brain with its tools off. The two share no process, flag set or configuration.

## Owners

| Owner | Does |
|---|---|
| `AgentProfiles.js` row `claude` | The argv, the `--settings` value, the account variable and the interrupt |
| `claude-hook` | Translates each hook event into task facts through `task-event`; holds a prompt and prints the answer Claude Code reads |
| `TaskRelay.js` | The one judge of prompt and answer files: their shape, which answer fits which prompt, the window and the ceiling |
| `TaskRunner.js` | Resolves the account, passes the hook values to the row, and gives the daemon `held()` and `answer(task, prompt, value)` |
| `Accounts.js::cliDirectory` | Maps a discovered Claude account id to its directory |

`Tasks.publish` copies `claude-hook` and `TaskRelay.js` into the task engine copy beside `Tasks.js` and `task-event`. A held hook outlives the plugin snapshot as a task does, so it never runs from the plugin directory.

## Launch

The row's argv is `claude --settings <json> -- <brief>`. The [CLI reference](https://code.claude.com/docs/en/cli-reference) documents `--settings` as a file or an inline JSON string; inline, it writes no file and lasts one session. `--` ends the options, as Omarchy's launcher does, so a goal that starts with `-` stays the prompt.

The JSON holds only `hooks`. Each event has one command hook in exec form: `command` is the daemon's absolute Node and `args` is `[<engine>/claude-hook, --state, STATE, --prompts, PROMPTS, --window, 600000, TASK, EVENT]`. With `args` set, Claude Code spawns the command with no shell ([hooks reference § Exec form](https://code.claude.com/docs/en/hooks), fetched 2026-10-02), so a state directory with a quote or a space reaches the hook intact. No group has a matcher, so each hook runs for every tool, notification type and end reason.

| Event | Timeout (s) | Why |
|---|---|---|
| `UserPromptSubmit` | 30 | The event's own default |
| `Notification`, `StopFailure` | 30 | Recording only |
| `PermissionRequest`, `Stop` | 660 | The 600 s window plus a margin, so the hook, not Claude Code, ends the hold |
| `SessionEnd` | 10 | Raises the event's 1.5 s budget for one record write |

The user's own hooks still run: settings levels merge hooks. The account is a discovered Claude account id from [account discovery](jarvis-accounts.md). `TaskRunner` refuses any other reference `task-account-unknown` before a record, and puts the directory in `CLAUDE_CONFIG_DIR`. The record keeps the id, not the directory.

## Event map

| Hook event | Task events | Stdout |
|---|---|---|
| `UserPromptSubmit` | `wait none`, `working` | none: Claude Code adds this event's stdout to the agent's context |
| `Notification` | `wait permission` for `permission_prompt`, `wait idle` for `idle_prompt`, `wait question` for `elicitation_dialog` and `elicitation_url_dialog`; no event for any other type | none |
| `PermissionRequest` | `wait permission`; after an answer, `wait none` | the answer's decision, or none |
| `Stop` | `turn-ended`; without a reported outcome, `wait question`, then after an answer `wait none` and `working` | `{decision: "block", reason}`, or none |
| `StopFailure` | `turn-failed` with the documented `error` type, else `unknown` | none |
| `SessionEnd` | `wait none` | none |

`Stop` is a turn end, never a finished task. A turn that ends before the agent ran the brief's outcome command waits on the user; one after it holds nothing. An allow prints `hookSpecificOutput.decision.behavior: "allow"`; a deny prints `"deny"` with a fixed message. A reply prints `reason: "The user answered: <text>"`, which Claude Code hands to the agent as the reason to continue.

A hook that fails writes one keyed `jarvis: claude-hook=` line, prints nothing and exits 1. It never exits 2, which Claude Code reads as a block on `Stop` and `UserPromptSubmit`. A permission request without a decision falls back to the agent's own prompt in its terminal.

## Relay

A held hook publishes one prompt file in `$XDG_RUNTIME_DIR/vgs/jarvis/prompts/` (mode 0700) and reads every 200 ms for its answer file. Both are mode 0600, written whole and renamed.

| Record | Shape |
|---|---|
| Prompt | `{v: 1, id, task, kind, tool, text, at, deadline}`: `kind` `permission` with the tool name, or `question` with `tool: null`. `text` is the tool name and its input as JSON, or the agent's `last_assistant_message`, with control characters other than a line break made spaces, cut to 4096 characters. Times are wall-clock milliseconds |
| Answer to a permission | `{v: 1, kind: "allow" \| "deny"}` |
| Answer to a question | `{v: 1, kind: "reply", text}`: non-empty, at most 4096 characters, no control character but a line break |

- `TaskRunner.held()` lists the unanswered prompts inside their window, oldest first. `TaskRunner.answer(task, prompt, value)` answers `answered` or a refusal: `prompt-unknown`, `prompt-expired`, `answer-invalid` or `answered-already`. A hard link publishes the answer, so a prompt takes one answer.
- Only the user's own words reach `answer`. The brain never answers a prompt: the plan's approval rule applies to an agent's prompt as to Jarvis's own actions.
- With no answer by the deadline the hook prints nothing and removes its prompt. The wait fact stays, and the agent asks in its own terminal. A later answer finds `prompt-unknown`.
- At most 32 prompts are held across all tasks. Past that a hook does not hold. Each new prompt first removes those past their deadline, which a hook ended by its timeout leaves behind.

## Deviations from the plan

- `UserPromptSubmit` joins the plan's five events. Without it a prompt the user types in the agent's terminal after a turn end leaves the task waiting.
- No daemon executor starts a task and no wire carries a typed answer. The `task` executor still needs a release port for the conversation's recipients ([task control § Launch](jarvis-task-control.md#launch)); task voice (J56) and the console's tasks tab (J58) are the consumers of `held` and `answer`.
- After the window, the plan's tmux `paste-buffer` answer route is not built. The agent's own terminal prompt is the route.

## Residual risk

- Hooks from managed settings, and the user's own hooks, run beside Jarvis's. `disableAllHooks` outside managed settings cannot remove managed hooks.
- Whether Claude Code withdraws a hook when the user answers a permission prompt in the terminal first is unverified. A Jarvis answer that arrives after it changes nothing the agent reads. J59's hand check covers it.
- After eight consecutive `Stop` blocks, Claude Code overrides the next and ends the turn, so a ninth relayed reply in a row reaches no agent.
- The stand-in follows the hooks reference, not a recording. Real program behaviour is J59's.

## Evidence

`scripts/test-jarvis-claude-task.js` runs in the [J09 world](validation-jarvis.md) with the real `TaskRunner`, `task-run.py` and engine copy, published from a snapshot that is then removed. The stand-in `claude` runs the hooks its `--settings` wires as the reference describes: exec form when `args` is set, input on stdin, a SIGTERM past the timeout. Its cases cover:

- the profile's argv and settings, read independently of the builder;
- the permission and question relay end to end, with the agent's environment and the hooks' engine-copy path;
- a denied permission, failed turns and the notification map;
- expiry for both held events, a full relay and the sweep of expired prompts;
- every hook failure row and its exit 1, the answer judge's refusal table, and an unknown account.

Its controls remove the exec form, the `--` before the brief, the silent `UserPromptSubmit`, the hold, the deny, the outcome check, the resumed turn, the failure and notification maps, the silent expiry, the exit code, the engine copy, the one answer, the answer kind, the expiry refusal, the answered filter, the ceiling, the sweep and the account check. `scripts/test-jarvis-accounts.js` covers `cliDirectory`, with controls for the provider and the absent directory.

## Omarchy comparison

Omarchy's `bin/omarchy-agent` on its default branch, read 2026-10-02, starts `claude --permission-mode auto -- "$prompt"` in a terminal and wires no hook: Claude Code's classifier answers its own prompts and the user watches the terminal. VGS takes the `--` spelling. It differs because the user may not be at the terminal: the agent keeps the user's own permission mode, and Jarvis relays each prompt to the user instead of switching the prompt off.
