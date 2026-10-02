# Jarvis Codex harness

Covers: shell/plugins/vgs.jarvis/backend/CodexAppServer.js, shell/plugins/vgs.jarvis/backend/CodexHarness.js, shell/plugins/vgs.jarvis/backend/HarnessGate.js, scripts/test-jarvis-codex-protocol.js, scripts/test-jarvis-codex.js, scripts/fixtures/jarvis-codex/

[D079](../decisions/D079-brains-wire-and-harness-adapters.md) names the harness adapter: a subscription runs only through the vendor's own program. [The plan § Brain adapters](../plans/v2-jarvis-plan.md#36-brain-adapters) gives Codex its rule: approvals are server requests. This page defines the Codex app-server harness, plan row J31. It implements the [brain interface](jarvis-brain.md#driver-contract) without tool-call events, uses the [tool bridge](jarvis-bridge.md) for its tools and the [action router](jarvis-approval.md) for its approvals.

## Owners

- `CodexAppServer.js` is the one judge of the app-server protocol. It builds every message Jarvis writes and narrows every line the program writes back. No other file parses it.
- `CodexHarness.js` owns one program per conversation: its process, its JSON-RPC connection, its thread, its private working directory and its bridge session. `create` is the [chained engine's](jarvis-engine.md) brain driver `codex-app-server`; `probe` is Account Verify's handoff.
- `HarnessGate.js` is the daemon's owner of a harness program's approval requests. It registers the router's `harness` executor and answers the program when the router admits or refuses a request.
- `Providers.js` holds the `codex` row: driver `codex-app-server`, key `none`, no image input. Its base, `https://chatgpt.com`, names the release recipient; Jarvis opens no socket to it.
- [Accounts](jarvis-accounts.md) resolves a Codex directory to the brain and owns its Verify. Jarvis never reads `auth.json` or any file under the account's directory.

## The program

`CodexHarness` starts `setpriv --pdeathsig KILL -- codex app-server --listen stdio://`. The environment is `Secrets.childEnvironment` of the daemon's plus `CODEX_HOME`, the account's directory, so the program reads its own login. No key variable, `VGSH_RUNNER_PID` or bridge token is in its environment or argv. Its working directory is a fresh private directory under the runtime directory, removed when the program ends. Closing stdin is the program's lease; a program alive 2 s later is killed. Its stderr is read and dropped, since its log can hold conversation text.

The handshake runs before the first turn, bounded by 30 s:

1. `initialize`, then `initialized`.
2. `config/read` from the working directory. Only the names of the user's own MCP servers are kept; their values, which can hold secrets, are dropped.
3. `thread/start`: ephemeral, `approvalPolicy: "untrusted"`, `approvalsReviewer: "user"`, `sandbox: "read-only"`, the composed guidance as `baseInstructions`, and the model when one is chosen. Its `config` switches off the built-in tool features, disables web search and the user-input tool, switches off every user MCP server by name and adds the bridge's server, `vgs_jarvis`, with the [launch contract](jarvis-bridge.md#launch-contract). The token travels only in this request, on the program's stdin. A user server named `vgs_jarvis` refuses the thread.
4. The reply must echo the untrusted policy, the user reviewer and a read-only sandbox without network, else `brain=codex-lockdown`.
5. `experimentalFeature/list` for the thread, one page. An enabled feature outside the table of features 0.160.0 reports enabled on such a thread refuses the brain as `brain=codex-feature name=<name>`. A newer program that enables a feature the table has not judged is refused until the table is reviewed.

## Built-in tools

Codex 0.160.0 offers its model `exec_command`, `write_stdin`, `view_image`, `apply_patch`, web search, `tool_search`, `request_user_input` and the goal tools by default, recorded against a loopback model stub. With the thread configuration above it offered `apply_patch` alone, plus `tool_search` and the MCP resource readers once an MCP server exists; those reach only MCP servers, and the bridge's is the only one running. The harness rule holds by its other branch for what remains: every remaining operation asks first. `apply_patch` sends a file-change approval and an MCP call sends an elicitation. No command tool is offered; a command approval that still arrives is routed like the others.

## Turns and release

`send` accepts a user turn of text items. Each item passes `Policy.release` against the conversation's recipient set and grants; an asked or withheld item travels as its marker. The released text, joined, is one `turn/start` input. The reply reports `{withheld, needed, labels}` as the wire brains do, so the engine audits the transfer before the first event. A turn with no released content refuses as `brain=codex-release-empty`.

Events are `item/agentMessage/delta` text and one `done` on `turn/completed` with status `completed`. A failed turn throws `brain=codex-turn-failed`. `cancel` sends `turn/interrupt` and resolves when the program reports the turn ended. The program keeps the thread's history; Jarvis counts user turns against the plan's bound of 40. A harness turn yields no tool-call event and takes no tool results.

`close` ends the program, the bridge session and the working directory, including a bridge session still opening when it is called. The engine closes the brain when its conversation ends, so a bridge session lives exactly as long as its conversation's program.

## Approvals

Each server request is judged by kind:

| Request | Answer |
|---|---|
| `item/fileChange/requestApproval` | Routed as `harness.files`: the written, moved and removed paths from the announced item and its diff |
| `item/commandExecution/requestApproval` | Routed as `harness.command`: the command and its working directory |
| `item/permissions/requestApproval` | Routed as `harness.permissions`, which has no row: the router refuses and audits it; the answer grants nothing |
| `mcpServer/elicitation/request` | Accepted only for a tool call of `vgs_jarvis` in this thread; the bridge then routes the call itself. Any other is declined |
| Any other request | JSON-RPC error -32601 |

A request outside the live turn of the conversation's generation is declined without reaching the router. `HarnessGate.ask` routes the others as `{kind: "approval"}`. The router admits only [harness rows](jarvis-policy.md) for that kind and never offers them to a brain. Policy judges every listed path through Denied; an overwrite or removal is destructive. A program's own command runs outside Sandbox.js, so it is refused unless the profile is trusted, where it needs physical confirmation. A held action keeps the program waiting until the user confirms or the hold ends; another request meanwhile is refused as `busy` and declined. The gate matches a router start to the one unanswered request with the same call, so that refusal leaves the held request startable. When the router starts the action, the gate answers `accept`, never `acceptForSession`, and reports the item's completion as the outcome. A refusal answers `decline`. The audit records each decision before the program proceeds.

## Verify

Accounts' Verify on a Codex directory calls `probe`: the same handshake with no MCP server, the instructions "Answer in one word." and one `turn/start` of the fixed probe text. Before it, `Accounts::released`, the same owner the HTTP probe and the Claude Code harness use, makes the release decision for that text to the `codex` recipient with Verify's consent grant and writes the release record. Verified requires the program's nonempty reply within 60 s. A failure names its cause, such as `codex-turn-failed`, `codex-refused` or `codex-exited`. The program runs in the daemon's runtime directory, which `AccountProviders.runtimeDirectory` names for both the service's hello and `Accounts`; without `XDG_RUNTIME_DIR` Verify refuses as `runtime-directory`. Claude directories verify through the [Claude Code harness](jarvis-claude.md#account-verify).

## Sources

The schema is generated by the program: `codex app-server generate-json-schema --out DIR` from `@openai/codex@0.160.0-linux-x64`, package SHA-256 `37a41d61c3399182b8c727b77090cc7a1566bd849d0f09070a0bbc6fec4c58dc`, generated 2026-10-02. `scripts/fixtures/jarvis-codex/app-server.schema.json` pins the excerpt the harness uses, with each source file's SHA-256 and its excerpt rules. Three fields the program sends without the experimental opt-in come from the `--experimental` bundle.

`scripts/fixtures/jarvis-codex/recorded.ndjson` is a sanitized recording of 0.160.0 in a loopback-only namespace with a scratch `CODEX_HOME`, no account and a loopback stub of the Responses API: a file change approved, an MCP tool call after its elicitation, and the thread and feature replies. Every recorded line validates against the excerpt.

## Bounds

| What | Ceiling | Past it |
|---|---|---|
| A program line | 8 MiB | `brain=codex-line-size`; the program is killed |
| Handshake | 30 s | the program is closed; the turn fails |
| Exit after stdin closes | 2 s | KILL |
| User turns per conversation | 40 | `brain=context-limit`, the wire brains' key; the engine ends the conversation cleanly |
| Feature list | one page of 500 | `brain=codex-feature-page` |
| A Verify turn | 60 s | `codex-probe-deadline` |

## Residual risk

- The program owns its sockets. Jarvis decides what text it hands over; the program's own context, such as its environment summary and the user's global instructions, is the vendor's.
- Policy judges a file change's paths when it is proposed; the program writes them after the gate admits it. A path replaced between the two is the program's to resolve.
- The daemon's Denied snapshot protects its XDG roots, the plugin directory it runs from, the explicit and hand-added account roots and every folder the [account name rule](jarvis-policy.md#real-paths) matches. A dev checkout's other files are the user's to change; an installed tree under `$XDG_DATA_HOME/vgs` is already protected. A snapshot that cannot be built, such as when an XDG root is a dangling link, refuses every path call as `path-context`.
- The recipient origin is a label for release decisions. A program signed in with an API key talks to `api.openai.com`; the provider row's retention text claims nothing either way.

## Evidence

- `scripts/test-jarvis-codex-protocol.js` checks every built message against the excerpt and replays the recording through the judge, with refusal rows and 52 disposable copies of the judge.
- `scripts/test-jarvis-codex.js` runs the real Session runner, router, Policy, Denied, Audit, bridge with the real `mcp-shim`, the gate and the harness in [J09](validation-jarvis.md), against `codex-stub.js` as the program. Its cases cover the lockdown and scrubbed environment, release markers, allowed, held, refused and stale approvals, the bridge call after its elicitation, lockdown refusals, cancel, close, a close while the bridge session opens, the turn bound ending the chained engine's conversation as `brain-ended`, Verify through Accounts with its release record before the turn, the accounts helper's keyed refusal of a refused turn, and the probe. Each of its 34 controls edits a disposable plugin copy and turns one case red.
- `scripts/test-jarvis-router.js`, `scripts/test-jarvis-policy.js` and `scripts/test-jarvis-tools.js` cover the harness rows; `scripts/test-jarvis-engine.js` covers selecting a Codex account.

## Omarchy comparison

Omarchy at `821ae58` starts `codex -s read-only -a on-request app-server` with each account's `CODEX_HOME` in `bin/omarchy-agent-usage-codex`, for rate limits only. VGS keeps the per-home program and the read-only sandbox. It runs turns, so it adds the untrusted policy, the tool lockdown and its verification, the bridge and the gate.
