# Jarvis tool bridge

Covers: shell/plugins/vgs.jarvis/backend/ToolBridge.js, shell/plugins/vgs.jarvis/backend/Mcp.js, shell/plugins/vgs.jarvis/backend/mcp-shim, shell/plugins/vgs.jarvis/backend/Private.js, scripts/test-jarvis-bridge.js, scripts/test-jarvis-mcp.js, scripts/fixtures/jarvis-bridge/

[The plan § Process model](../plans/v2-jarvis-plan.md#32-process-model-and-capture-lifetime) defines `mcp-shim`: the stdio MCP server a harness brain starts, relaying to `tools.sock` so the harness's tools reach the same router. [D079](../decisions/D079-brains-wire-and-harness-adapters.md) names the harness adapters. [D082](../decisions/D082-jarvis-approval-bound-to-the-action.md) makes the [action router](jarvis-approval.md) the one gate. The bridge adds no decision of its own.

## Owners

- `ToolBridge.create({router, state, audit, directory})` owns the daemon's bridge: the socket, the session token, its connections and the bridge's calls pending in the router. `directory` is hello's `directories.runtime`. Creation touches no file.
- `open({gen, recipients})` starts the one session for a conversation generation and its frozen [recipient set](jarvis-release.md#recipient-and-item-contract). A second open refuses `bridge=session-open`. The session's `close` and the owner's `close` end every connection, close the listener and revoke the token; both are idempotent. The daemon closes the owner in teardown before the router closes.
- `Mcp.js` is the one MCP judge. `Mcp.accept(line, phase)` returns the next phase and one act: a reply, nothing, a tool list or a tool call. It also builds every message the bridge writes. No other file parses MCP.
- `mcp-shim` authenticates and relays bytes. It parses no MCP.
- `Private.directory` owns the private-directory rule for the bridge's runtime directory and the [audit store](jarvis-audit.md#privacy-and-storage).
- `Tools.wireNames` owns the model-facing tool name. The [wire brains](jarvis-brain.md#driver-contract) and the bridge use the same spelling.
- The daemon opens no session itself. A harness brain opens one per conversation, writes the launch contract into the harness's MCP configuration and closes it when the conversation ends: the [Claude Code harness](jarvis-claude.md) through a private MCP configuration file, [the Codex harness](jarvis-codex.md#the-program) through its thread's configuration. J30 owns the other.

## Launch contract

`open` resolves the one producer of the shim's launch contract.

| Field | Value |
|---|---|
| `command` | `process.execPath`, the daemon's Node |
| `args` | `[<absolute path of backend/mcp-shim>]` |
| `env` | `VGS_JARVIS_TOOLS_SOCKET` (the socket path) and `VGS_JARVIS_TOOLS_TOKEN` (64 hex characters, 32 random bytes) |
| `close()` | Ends this session |

The token appears only in that environment. The shim reads both values from its environment and never from argv.

## Bridge wire

The shim connects to `tools.sock` and writes one line, `{"v":1,"type":"hello","token":"..."}`. The bridge answers `{"v":1,"type":"ready"}` or one refusal line, `{"v":1,"type":"refused","reason":R}`, and ends the connection. After `ready`, each line in either direction is one MCP JSON-RPC message. A refusal after `ready` writes no line, since the shim relays to the harness's stdout, which carries only MCP: the bridge logs it and ends the connection.

| Reason | Cause |
|---|---|
| `hello` | The first line is not JSON, or not exactly the keys `v`, `type` and `token` with `v` 1, `type` `hello` and a string token |
| `token` | The token is not the session's. The bridge compares SHA-256 digests with `timingSafeEqual`, so the comparison takes the same time for any length |
| `hello-deadline` | No hello within 2 s |
| `connections` | The session already holds four connections |
| `line-size` | A line passes 256 KiB |

Each refusal logs `jarvis: bridge=refused reason=R` on stderr. A refused connection leaves the session's count at once, buffers nothing more and is destroyed once its last write flushes, even when the peer keeps its own side open. It routes nothing, including lines queued behind its hello.

| Shim exit | First stderr line |
|---|---|
| 0 | none: stdin reached EOF |
| 1 | `mcp-shim: bridge=refused reason=R` |
| 64 | `mcp-shim: environment=VGS_JARVIS_TOOLS_SOCKET` or `...TOKEN` |
| 69 | `mcp-shim: bridge=unavailable cause=CODE`, or `mcp-shim: bridge=closed` when the connection drops |
| 74 | `mcp-shim: stdout=CODE` |

## MCP subset

The bridge speaks the initialization-era protocol, versions `2025-11-25` and `2025-06-18`. It answers an `initialize` that names either version with that version, and any other version with `2025-11-25`, as the [2025-11-25 lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle) requires. The stdio framing is one message per line with no embedded newline, from the [2025-11-25 transports page](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

| Method | Phase | Answer |
|---|---|---|
| `ping` | any | `{}` ([ping](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/ping)) |
| `initialize` | before it | `protocolVersion`, `capabilities: {tools: {}}`, `serverInfo: {name: "vgs-jarvis", version: "1"}`; later ones refuse -32000 |
| `notifications/initialized` | after `initialize` | none; tools become available |
| `tools/list` | after the notification | `tools`: name, description and `inputSchema` per offered row; no cursor |
| `tools/call` | after the notification | a tool result, or a protocol error |

- Other requests answer -32601. Other notifications are never answered. A request before its phase answers -32000, the implementation-defined server error. Unreadable JSON answers -32700, and a message that is not a request or notification answers -32600. Parameters that are not an object, or a `tools/call` without a string `name` or with non-object `arguments`, answer -32602.
- Ids are strings or integers. A null or fractional id is invalid, as the [2025-11-25 base protocol](https://modelcontextprotocol.io/specification/2025-11-25/basic) requires. An error whose request id is unreadable omits `id`, as that page allows.
- A modern client of the [2026-07-28 revision](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio) probes with `server/discover` first. The -32601 answer marks the bridge as a legacy server, and the client falls back to `initialize`.
- The bridge declares no `listChanged`, tasks, resources or prompts. The offer changes only when an executor registers.

The sources are the specification pages above and the [2025-11-25 schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/3098fe94caa1b9e0afaaa6d30e040b61d5802471/schema/2025-11-25/schema.json), fetched 2026-10-01. `scripts/fixtures/jarvis-bridge/mcp.schema.json` pins the subset and states its excerpt rules. The definitions of every field the bridge writes are the same in the 2025-06-18 schema, except that its error responses always carry an id.

## Calls and results

- `tools/list` answers from `router.offer()`. A name maps to its Tools id through `Tools.wireNames`; `windows.list` is `windows_list`. `inputSchema` is the row's closed JSON Schema object.
- `tools/call` with a name outside the current offer answers -32602, as the [2025-11-25 tools page](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) requires for an unknown tool. Nothing is routed.
- A session serves the live thinking turn of its own generation. When the Session generation differs or no thinking turn exists, the call answers the tool result `{"kind":"refuse","reason":"stale-turn"}` with `isError: true`. Nothing is routed or audited.
- Otherwise the bridge mints an id, `bridge-<uuid>`, and calls `router.route({kind: "tool-call", id, tool, arguments}, turn)`. The router judges the call, holds an approval or starts the executor. The bridge never calls Policy.decide, an executor or the approval path.
- The router's result port calls `bridge.deliver(value)` first. It returns whether the bridge minted the value's id; the daemon passes any other value to the brain port.
- A held approval leaves the MCP request open until the router delivers. While a call holds the router's serial slot, another call answers the router's `busy` refusal.
- Each result passes `Policy.release` against the session's recipient set. `ask` and `withhold` send the marker: no release-grant owner exists yet, so the bridge fails closed. `Audit.before` records the release before the bridge writes. A failed record answers `{"kind":"refuse","reason":"audit-write"}`.
- The answer is `{content: [{type: "text", text}], isError}`. `isError` is false only for a completed outcome. Refusals, failed, unknown and cancelled outcomes set it.
- A result for a closed connection is dropped without a release record. The router marks each result `final` unless it is a timeout whose actual completion follows; the bridge forgets a call only on its final result, so that completion is dropped too and never reaches the brain.

## Bounds

| What | Ceiling | Past it |
|---|---|---|
| A wire line, newline included | 256 KiB, the plan's wire bound | `line-size`; the connection ends, since no id is readable. After `ready` no refusal line is written |
| Connections per session | 4: one harness connection, plus its restart while the old one drains | `connections` |
| Time to the hello | 2 s; the shim writes it on connect | `hello-deadline` |
| Pending calls | The router's serial slot: one live call, plus one timed-out call awaiting its actual completion | The router refuses `busy` |
| Socket path | 107 bytes; [unix(7)](https://man7.org/linux/man-pages/man7/unix.7.html) `sun_path` holds 108 with its terminating byte | `open` refuses `bridge=socket-path` |

## Socket and runtime directory

- `open` creates the runtime directory with `Private.directory`: every missing component with mode 0700, no link or non-directory anywhere in the path, the leaf owned by the user and set to 0700.
- An existing `tools.sock` is replaced only when `lstat` reports a socket the user owns, which a daemon killed outright leaves behind. Anything else refuses `bridge=socket-type` and stays untouched. The socket itself takes mode 0600.
- Closing the listener unlinks the socket. Node closes the pipe through libuv's [`uv__pipe_close`](https://github.com/libuv/libuv/blob/v1.48.0/src/unix/pipe.c), which unlinks its bound name; Node 22 ships libuv 1.48.

## Residual risk

The token protects the socket from processes that do not hold it. Another program of the same user can read the harness's environment and take the token. It then reaches the same router a harness reaches: Policy, approval and audit still apply, and it cannot confirm a held action. The [approval residuals](jarvis-approval.md#wire-and-residual-boundary) name the same-user boundary the bridge inherits. Another user cannot reach the socket through the 0700 directory.

## Evidence

- `scripts/test-jarvis-bridge.js` runs the real Session reducer, SessionRunner, ToolRouter, Policy, Audit and ToolBridge on scratch files in [J09](validation-jarvis.md), and the real `mcp-shim` as a child with an explicit environment. The suite is the stub harness. Stand-in executors register through the router. Each message is checked against the pinned excerpt with `scripts/fixtures/schema-check.js`.
- Its cases cover the lifecycle and offer, an allowed call proven by its pre-start audit record and executor start, a held approval in Session state, refusals as `isError`, refused hellos and tokens with nothing routed or audited, stale generations and turns, the release marker for a file result to a network recipient against plain text for a local set, protocol errors, close and reopen, the runtime directory and socket checks, dropped results and a timed-out call. A last check proves the real cases leave no socket, listener or child behind.
- Bounds: the line at 256 KiB and one byte past it, with the shim's stdout holding only JSON-RPC lines afterwards; four waiting connections and a refused fifth; the 2 s delay each hello timer requests, read from the injected clock, and the refusal when it fires; half-open peers that ignore their refusal, which are destroyed and free their slots for a valid hello; the socket path at 107 bytes accepted and 108 refused.
- Disposable copies remove each rule: the token and hello checks, routing through the router, the brain's own results, the generation binding, release, its audit record, `isError`, the unknown tool, the socket type and path and its 107-byte edge, each bound and the hello delay, one session, close, closing a refused connection, the silent refusal after `ready`, the private directory and its mode, the dropped results, deletion only on `final`, a router that marks a timeout final, and three shim rules. Each turns its case red once.
- `scripts/test-jarvis-mcp.js` runs the judge's table, every line and reply checked against the excerpt, with a control per rule. `scripts/test-jarvis-tools.js` holds the wire-name table and its controls. `scripts/test-jarvis-daemon.js` proves the real daemon's startup creates no `tools.sock`; a copy that opens a session turns it red.

## Omarchy comparison

The read-only omarchy-voice reference at `8ef9d60` keeps its local control socket in an owner-only directory with mode 600. Its `SECURITY.md` states that other processes of the same user are trusted, with no same-user authentication boundary. Omarchy at `c05d901` (`quattro`) starts agent programs from `bin/omarchy-agent` and its shell `agents` plugin reads their usage. It has no tool bridge or MCP server. VGS keeps the owner-only directory and adds a per-session token bound to one conversation generation, and every call passes the one router.
