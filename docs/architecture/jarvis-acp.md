# Jarvis ACP harness

Covers: shell/plugins/vgs.jarvis/backend/AcpClient.js, shell/plugins/vgs.jarvis/backend/AcpHarness.js, scripts/test-jarvis-acp-protocol.js, scripts/test-jarvis-acp.js, scripts/fixtures/jarvis-acp/

[D079](../decisions/D079-brains-wire-and-harness-adapters.md) names the harness adapter: a subscription runs only through the vendor's own program. [The plan § Brain adapters](../plans/v2-jarvis-plan.md#36-brain-adapters) gives ACP agents their rule: Copilot runs read-only operations unasked, so it starts with its built-in tools excluded or is refused. This page defines the Agent Client Protocol harness, plan row J30, with GitHub Copilot as its one agent. It implements the [brain interface](jarvis-brain.md#driver-contract) without tool-call events, uses the [tool bridge](jarvis-bridge.md) for its tools and the [action router](jarvis-approval.md) for the agent's permission requests, through `HarnessGate` as [the Codex harness](jarvis-codex.md#approvals) does.

## Owners

- `AcpClient.js` is the one judge of ACP v1. It builds every message Jarvis writes and narrows every line the agent writes back. No other file parses it.
- `AcpHarness.js` owns one agent program per conversation: its process, its JSON-RPC connection, its session, its private working directory and its bridge session. Its program table holds one row per agent. `create` is the [chained engine's](jarvis-engine.md) brain driver `acp`; `probe` is Account Verify's handoff.
- `Providers.js` holds the `copilot` row: driver `acp`, key `none`, no image input, base `https://api.githubcopilot.com`. The base names the release recipient; Jarvis opens no socket to it.
- `AccountProviders.js` holds the `copilot` account row: variable `COPILOT_HOME`, prefix `.copilot`, marker `config.json`, no status command. [Accounts](jarvis-accounts.md) resolves a Copilot directory to the brain and owns its Verify. Jarvis opens no file under the account's directory.

## The program

`AcpHarness` starts `setpriv --pdeathsig KILL -- copilot` with the row's argv, then `--model <model>` when one is chosen. The environment is `Secrets.childEnvironment` of the daemon's plus `COPILOT_HOME`, the account's directory, so the program reads its own login. No key variable, GitHub token variable, `VGSH_RUNNER_PID` or bridge token is in its environment or argv. Its working directory is a fresh private directory under the runtime directory, removed when the program ends. Closing stdin is the program's lease; a program alive 2 s later is killed. Its stderr is read and dropped.

| Argument | Why |
|---|---|
| `--acp --stdio` | The ACP server on stdin and stdout |
| `--excluded-tools` and every built-in name | The [command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference) lists `bash`, `powershell`, `list_bash`, `read_bash`, `stop_bash`, `write_bash`, `view`, `create`, `edit`, `apply_patch`, `task`, `list_agents`, `read_agent`, `write_agent`, `ask_user`, `glob`, `grep`, `rg`, `skill` and `web_fetch`; the [tools page](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/allowing-tools) adds `web_search`. The model does not see them |
| `--deny-tool shell write read url memory` | A built-in the list misses still cannot run a command, write, read, fetch or remember. Copilot's `help permissions` states that a denial beats every allow |
| `--allow-tool vgs_jarvis` | The bridge's tools run without a prompt. The router is their gate |
| `--disable-builtin-mcps` | GitHub's own MCP servers stay off |
| `--no-custom-instructions`, `--no-ask-user`, `--no-auto-update`, `--disallow-temp-dir` | No instructions file, no question tool, the installed version only, no temporary directory access |

The handshake runs before the first prompt, bounded by 30 s:

1. `initialize` offers no file system and no terminal. The reply must be protocol version 1 from the agent named `Copilot` at version 1.0.60 or later, the release whose ACP server honours the tool filters; otherwise `brain=acp-agent`, `acp-agent-version` or `acp-protocol`.
2. `session/new` in the working directory, with the bridge's server `vgs_jarvis` as the one MCP server and its [launch contract](jarvis-bridge.md#launch-contract). The token travels only in this request, on the program's stdin. A program that is not signed in answers ACP's `auth_required`, which refuses as `brain=acp-signed-out`; Jarvis never calls `authenticate`.

## Built-in tools

ACP reports no tool list, so the harness verifies the lockdown from what the agent reports it runs. A `tool_call` or `tool_call_update` whose kind is `read`, `edit`, `delete`, `move`, `search`, `execute`, `fetch` or `switch_mode`, and whose status says it ran, must carry the id of a permission request the gate saw. Otherwise the conversation ends with `brain=acp-builtin kind=<kind>` and its program is killed. A call announced `pending` before its request is not a run. An MCP call reports `other`; a server other than the bridge is not allowed and asks first.

## Turns and release

`send` accepts a user turn of text items. Each item passes `Policy.release` against the conversation's recipient set and grants; an asked or withheld item travels as its marker. The released text, joined, is one text block of `session/prompt`. ACP has no system prompt, so the composed guidance leads the first prompt as its own block. The reply reports `{withheld, needed, labels}` as the wire brains do, so the engine audits the transfer before the first event. A turn with no released content refuses as `brain=acp-release-empty`.

Events are the text of `agent_message_chunk` updates and one `done` when the prompt answers `end_turn`. Another stop reason fails as `brain=acp-stop-<reason>`; a non-text reply block is not spoken. `cancel` answers every open permission request `cancelled`, as the [prompt turn page](https://agentclientprotocol.com/protocol/prompt-turn) requires, sends `session/cancel` and resolves when the prompt answers. The program keeps the history; Jarvis counts user turns against the plan's bound of 40. `close` ends the program, the bridge session and the working directory, including a bridge session still opening.

## Permissions

`session/request_permission` is judged by the tool call it names, merged with what the agent announced under that id:

| Kind | Routed as |
|---|---|
| `edit` | `harness.files`, every named path written, with the diffs |
| `delete` | `harness.files`, every named path removed |
| `move` | `harness.files`, every named path judged as both source and destination, since only the agent knows which is which |
| `execute` | `harness.command`: the raw input's command and its directory, else the session's |
| any other | `harness.permissions`, which has no row: the router refuses and audits it |

A request outside the live prompt, for another session, or without an `allow_once` option is rejected without reaching the router. `HarnessGate.ask` routes the others as `{kind: "approval"}`; Policy, the held approval and the audit judge them as they judge a Codex request. When the router starts the action, the harness answers the `allow_once` option, never `allow_always`, and reports the call's `completed` or `failed` update as the outcome. A refusal answers `reject_once`, or `cancelled` without one. `fs/*`, `terminal/*` and any other agent request answer -32601.

## Verify

Accounts' Verify on a Copilot directory calls `probe`: the same handshake with no MCP server and one prompt of "Answer in one word." and the fixed probe text. `Accounts::released` makes the release decision for that text to the `copilot` recipient with Verify's grant and writes the release record first. Verified requires `end_turn` and a nonempty reply within 60 s. A failure names its cause, such as `acp-signed-out`, `acp-stop-refusal` or `acp-exited`. Copilot documents no login status command, so discovery shows a Copilot directory as Found and starts no program; `config.json` exists signed in or not.

## Sources

`scripts/fixtures/jarvis-acp/acp.schema.json` pins the excerpt of `schema/schema.json` from `@agentclientprotocol/sdk` 1.7.0, with the tarball's and the file's SHA-256, fetched 2026-10-02, and its excerpt rules. `recorded.ndjson` is a sanitized handshake of Copilot 1.0.91 (`@github/copilot-linux-x64`, SHA-256 `11d1dcd5a30d59b270b201e6eeea78fc8b89a59fa2f7da31fd62b35bdd708104`) in a loopback-only namespace with a scratch `COPILOT_HOME` and no account: the `initialize` reply and the `auth_required` refusal of `session/new`. The same binary accepted the argv above. The signed-in flows are synthetic lines checked against the excerpt.

## Copilot SDK

The [Copilot SDK](https://github.com/github/copilot-sdk) embeds the same runtime through a package per language. It speaks Copilot's own JSON-RPC protocol to `copilot --headless`, not ACP.

| | Copilot SDK | `copilot --acp` |
|---|---|---|
| Dependency | An npm, pip or other package; the Node package bundles the CLI | None: one judge file |
| Protocol | Copilot's own | ACP v1, shared with Gemini CLI and OpenCode |
| Tool filters | Per session | Fixed by argv for the program's life |
| Permission request | Typed kinds such as `shell`, `write`, `read`, `mcp`, `url` | A tool call and `allow_*` or `reject_*` options |
| Login | The CLI's own, or a token the caller passes | The CLI's own |

VGS takes the ACP route: D079 admits no npm dependency, and one program per conversation makes the argv filters per conversation.

## Bounds

| What | Ceiling | Past it |
|---|---|---|
| A program line | 8 MiB | `brain=acp-line-size`; the program is killed |
| Handshake | 30 s | the program is closed; the turn fails |
| Exit after stdin closes | 2 s | KILL |
| User turns per conversation | 40 | `brain=context-limit`; the engine ends the conversation cleanly |
| A Verify prompt | 60 s | `acp-probe-deadline` |

## Residual risk

- The tool filters rest on Copilot honouring its own flags. The program reports a call after it starts, so a built-in read that the filters miss may run before the harness ends the program.
- The user's own MCP servers in `COPILOT_HOME` may start; their calls ask first and the gate refuses them.
- The program owns its sockets and its logs under `COPILOT_HOME`, which can hold conversation text.
- A newer agent that removes a flag, or a kind the table lacks, is refused only when it reports the run.

## Evidence

- `scripts/test-jarvis-acp-protocol.js` checks every built message against the excerpt, replays the recording through the judge, and narrows synthetic updates and requests, with 25 disposable copies of the judge.
- `scripts/test-jarvis-acp.js` runs the real Session runner, router, Policy, Denied, Audit, bridge with the real `mcp-shim`, the gate and the harness in [J09](validation-jarvis.md), against `copilot-stub.js`. Its cases cover the argv and scrubbed environment, the model, release markers, allowed, held, refused and stale permission requests, the bridge call, refused file system and terminal requests, the built-in tripwire, handshake refusals, cancel with a held request, close, a close while the bridge opens, the turn bound through the chained engine, discovery and Verify through Accounts, the accounts helper's keyed refusal, and the probe. Each of its 38 controls edits a disposable plugin copy and turns one case red.

## Omarchy comparison

Omarchy at `821ae58` starts `copilot --allow-all` in a terminal as a coding agent from `bin/omarchy-agent`. It runs no ACP client. VGS runs Copilot as a brain, so it inverts that grant: built-ins excluded and denied, the bridge the only allowed server, and every other request through the gate.
