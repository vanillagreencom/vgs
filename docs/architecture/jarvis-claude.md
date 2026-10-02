# Jarvis Claude Code harness

Covers: shell/plugins/vgs.jarvis/backend/ClaudeCode.js, scripts/test-jarvis-claude.js, scripts/fixtures/jarvis-claude/

[D079](../decisions/D079-brains-wire-and-harness-adapters.md) makes a subscription brain a harness adapter: the vendor's own program, which owns its login. [The plan § Brain adapters](../plans/v2-jarvis-plan.md#36-brain-adapters) sets the harness rule: the program's own tools are off, or each of its operations asks Policy first; otherwise it is refused as a brain. Claude Code meets the rule with its built-in tools off and the [tool bridge](jarvis-bridge.md) as its only MCP server, so every call reaches the [action router](jarvis-approval.md). This page defines that adapter and the Claude route of [account Verify](jarvis-accounts.md#account-state-and-verification).

## Owners

- `ClaudeCode.create(...)` owns one harness conversation: the `claude` process, its private working directory, its MCP configuration file and the bridge session it opened. A conversation is one process. A fault, an unanswered interrupt or the program's exit ends it; a later `send` refuses `brain=harness-ended`.
- `messageOf` is the one narrowing door for a stream-json output line. Fields it does not read pass unread.
- The tool bridge, router, Policy, approval and Audit judge every tool call. The adapter never routes a call, answers a tool result or decides an action.
- The caller owns the release audit, as for the [wire brains](jarvis-brain.md#driver-contract): it runs the first read of `events` inside `Audit.before`. Account Verify does so in `Accounts::released`.
- The [chained engine](jarvis-engine.md) still selects wire brains only, and `Accounts::resolve` still resolves no subscription. Connecting a harness conversation to the engine's ports is not part of this adapter.

## Interface

| API | Meaning |
|---|---|
| `create({directory, model, recipients, bridge, parent, environment, clock?})` | `directory` is the account's `CLAUDE_CONFIG_DIR`. `model` is `""` for the program's default, or a name of at most 120 printable characters that does not start with `-`. `recipients` is the conversation's frozen set; the brain recipient is network, Anthropic's API origin. `bridge` is `null` or `{open()}`, resolving the bridge's launch contract once. `parent` is the private runtime directory. Nothing starts until the first request. |
| `start({instructions, tools})` | Once per conversation. `tools` is the router's offer; `Tools.wireNames` gives each its bridge name, `mcp__vgs-jarvis__<name>` in Claude Code. An offer needs a bridge. |
| `send(turn, grants?)` | `turn` is `{kind: "user", items, images?}`, as for the wire brains. It returns `{release: {withheld, needed, labels}, events}`; nothing leaves before the caller reads `events`. A `tool-results` turn refuses `brain=tool-results`: the bridge answers each call. |
| `events` | Yields `{kind: "text", text}` for each text block, then `{kind: "done", reason: "stop"}` on a successful result. Every other ending throws a keyed error. |
| `cancel()` | Interrupts the live turn and resolves once its result is read, or once the process is gone. |
| `close()` | Ends the conversation and resolves once the process is gone, the bridge session closed and the working directory removed. |
| `verify({...})` | One tool-less conversation for account Verify; below. |

## Launch

The adapter starts `claude` from the daemon's `PATH` with this argv. Each flag is from the [CLI reference](https://code.claude.com/docs/en/cli-reference), fetched 2026-10-02.

| Flag | Why |
|---|---|
| `-p --input-format stream-json --output-format stream-json --verbose` | Print mode with a multi-turn JSON stream in and out. Stream-json output needs `--verbose`. |
| `--tools ""` | Every built-in tool off. |
| `--strict-mcp-config --mcp-config <file>` | The bridge is the only MCP server; the user's and the project's servers are ignored. |
| `--allowedTools mcp__vgs-jarvis` | The bridge's tools run without a Claude Code prompt. The router is the gate. |
| `--permission-mode dontAsk` | Anything else that would prompt is denied. |
| `--settings {"disableAllHooks":true}` | The user's hooks would run commands outside the gate. |
| `--disable-slash-commands --no-session-persistence` | No skills or commands, and no session file in the account directory. |
| `--system-prompt <instructions>`, `--model <model>` | Shipped guidance, when not empty; the chosen model, when not empty. |

- The MCP configuration is `mcp.json`, mode 0600, beside the working directory `cwd/` in a fresh directory of mode 0700 under `parent`. It holds the launch contract, so the bridge token stays out of argv, as the bridge's contract requires. The working directory is empty, so no project file loads.
- The child's whole environment is `LANG`, the daemon's `PATH`, `HOME` and XDG directories, `CLAUDE_CONFIG_DIR` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. No key variable, token or runner pid passes.
- The child leads its own process group. A fault kills the group; close sends SIGTERM, then SIGKILL after 2 s. Stderr is drained and never kept: it can echo conversation text.
- The program owns its login and its sockets. Jarvis opens no Claude credential file and copies no token.

## Wire

The wire is [Anthropic's stream-json](https://code.claude.com/docs/en/headless), typed in the Agent SDK's `sdk.d.ts`. `scripts/fixtures/jarvis-claude/stream-json.schema.json` pins the excerpt: package 0.3.287 for Claude Code 2.1.287, its tarball integrity and the file's SHA-256, fetched 2026-10-02, with the transcription rules.

| Message | Meaning |
|---|---|
| user turn | `{type: "user", message: {role: "user", content}, parent_tool_use_id: null}`. Content is a text block per released item or marker, and a base64 image block per released PNG or JPEG image |
| `system`, `init` | Every tool must be in the offer, and the one server `vgs-jarvis` connected; without an offer, no tool and no server. Otherwise `brain=harness-tool name=N` or `brain=harness-mcp` |
| `assistant` | Text blocks are yielded; thinking passes. A `tool_use` outside the offer, any other block, a reply before init or a subagent message fails the turn |
| `result` | `success` without `is_error` ends the turn. An API error fails as `harness-api-error status=S`; an error subtype as `harness-<subtype>` |
| `control_response` | Accepted once per interrupt written, in its turn, between turns or in a later turn; any other fails `harness-control` |
| `control_request` | Fails: only a permission host answers one, and none exists |
| other | Tool result echoes, retries and notices pass unread |

Between turns only notices, an init message and a late interrupt answer may arrive; any other message fails `harness-order` and ends the conversation.

`EndConversation` is the one built-in Claude Code keeps while any MCP tool remains. No flag removes it, and it reads and changes nothing ([tools reference](https://code.claude.com/docs/en/tools-reference)). The adapter accepts it only beside a non-empty offer. A call to it ends the harness conversation; the turn fails once the program exits or misses its result.

## Release

Each user item passes `Policy.release` against the conversation's recipient set with the caller's grants. An asked or withheld item travels as its marker, and `release.needed` and `release.withheld` name the labels. A turn that releases nothing refuses `brain=release-empty` before any process starts. History lives in the program, so a sent turn is never released again. Each tool result passes release in the bridge.

## Cancel and close

`cancel()` writes the Agent SDK's interrupt control request, `{type: "control_request", request_id, request: {subtype: "interrupt"}}`, which `sdk.d.ts` types as `SDKControlRequest`. The turn holds in cancelling until its result arrives; text queued before the interrupt or read after it never reaches the caller, and the next read throws `brain=cancelled`. The conversation keeps its program, and the result disarms the bound. A turn can end before the program reads the interrupt; its answer then follows the result and is accepted where it arrives. With no result within the plan's 2 s, the process group is killed and the conversation ends. The CLI reference documents SIGINT to end a turn, but a signal reaches the whole process with no acknowledgement and no turn identity.

## Bounds

| What | Ceiling | Past it |
|---|---|---|
| A stream-json output line | 1 MiB, the wire brains' line bound | `harness-line-limit`; the conversation ends |
| One turn's output | 8 MiB, the wire brains' response bound | `harness-turn-limit` |
| A user turn's line | 20 MiB, the wire brains' request bound | `request-limit` |
| User turns | 40, the plan's context bound | `context-limit`; nothing is summarised |
| Offered tools | 64 | `tools` |
| An interrupt's answer | 2 s, the plan's cancel bound | the process group is killed |

## Account Verify

A Claude subscription account verifies through `ClaudeCode.verify`: the same argv with no MCP server, the system prompt "Answer in one word." and the fixed prompt "Reply OK." `Accounts::released` judges the command-labelled prompt for the account's recipient set under the user's Verify grant and records it with `Audit.before` before the program starts. Verify is `{kind: "inference"}` only after a successful result with non-empty text. Another subscription keeps `subscription-handoff-unavailable`. The account directory is rechecked without following a link first.

## Residual risk

Managed settings an organisation installs can still configure hooks or servers the user flags do not remove. The program's own network traffic is outside `net.js`; release judges what Jarvis hands it, and its recipient is Anthropic. Stream-json is typed, not schema-published, so a vendor change can fail the turn closed. Real program behaviour is J59's hand check.

## Evidence

- `scripts/test-jarvis-claude.js` runs in the [Jarvis test world](validation-jarvis.md). Its stand-in `claude` reads its script from the account directory, honours `--tools` and `--strict-mcp-config`, starts the configured MCP server and checks every line it reads and every line it builds against the excerpt. Only a refusal row's malformed or out-of-excerpt line, and a line that never ends, are written unchecked.
- Its cases cover the pinned argv and environment, with keys, tokens and a runner pid planted in what the adapter and Verify are handed, one program per conversation, a scripted call through the real `mcp-shim`, bridge and router with its pre-start audit record, a held approval confirmed in Session, a locked refusal, built-in tools in init or in a call, a failed server, `EndConversation` without an offer, an answered and an unanswered interrupt on the manual clock, text queued at the interrupt, an answer that follows its turn's result, a foreign answer, each result kind, malformed messages, a reply before init or between turns, a line that never ends, release markers and grants, each bound in the table at and past its ceiling but the interrupt's, which the two interrupt cases cover, close, and Verify through the real Accounts judge, text before a failed result or an exit included.
- Disposable mutants remove each rule: the tools, strict-config, hook and session flags, the token file, the environment and a key added to its allowlist, one process, the init and call checks, the server check, the `EndConversation` scope, release, the empty release, the interrupt, its timer, disarm and bound, the cancelled read, the late and foreign answers, the subagent, result, API error, block, control request, init order and between-turns checks, the line and unterminated line, turn, request, context and tool bounds, close's session, late session and directory, and Verify's route, audit, result and text proofs and reason.

## Omarchy comparison

Omarchy's `bin/omarchy-agent` on its default branch, `quattro`, read 2026-10-02, starts `claude --permission-mode auto` in a floating terminal, with `CLAUDE_CONFIG_DIR` set to the chosen account home; `omarchy-agent-prompt` passes a prompt to it. The user watches and steers that interactive session, and Claude Code's own tools and classifier act. VGS takes the per-account `CLAUDE_CONFIG_DIR` and the unmodified program. It differs because no human watches a voice turn: print mode with stream-json, built-in tools off, the bridge as the only server and the release gate on each turn. omarchy-voice posts to OpenAI with a key and runs no subscription program.
