# Jarvis audit

Covers: shell/plugins/vgs.jarvis/backend/Audit.js, shell/plugins/vgs.jarvis/backend/Redact.js, scripts/test-jarvis-audit.js, scripts/test-jarvis-redact.js

[D070](../decisions/D070-jarvis-action-policy.md) assigns the pre-action audit boundary. The [plan's policy section](../plans/v2-jarvis-plan.md#37-policy-authority-effects-approval-audit) defines the record. The [bounds section](../plans/v2-jarvis-plan.md#311-bounds) defines retention.

## Integration

`Audit.js::create` supplies the writer interface for the [tool router](jarvis-approval.md), the [tool bridge](jarvis-bridge.md#calls-and-results) and the network door. The daemon acquires its writer on first hello. Approval refusals and privacy cleanup produce records. The [chained engine](jarvis-engine.md) audits each transfer before it starts. The module tests invoke the real audit boundary with fixture callbacks, not production executors.

J19 owns authorization, serial execution and approval binding. Its router must call `before` after authorization and before it starts an executor. J22 must use the same boundary before an authorized outbound transfer. Held, refused, expired and replaced decisions use `record` without starting work. Later outcomes use `record` with the original generation and operation identity. Recording an outcome never cancels or reverses an action that already started.

The caller owns one writer for the daemon's lifetime. It closes that writer on lease loss. The VGS instance lock and service-child lease supply process exclusivity. `create` refuses a second owner of the same state path in one process. This interface is not a multi-process log service.

## Contract

| Member | Contract |
|---|---|
| `create({ state, auditDays?, now? })` | `state` is the absolute `$XDG_STATE_HOME/vgs/jarvis` path from the trusted shell snapshot. `auditDays` defaults to 30 and accepts integers from 1 through 365. `now` returns wall-clock milliseconds and defaults to `Date.now`. Invalid options throw a keyed error. |
| `record(event)` | Synchronously appends and flushes one decision or outcome. Returns `{ kind: "recorded" }` or `{ kind: "refuse", reason: "audit-write", cause }`. |
| `before(event, start)` | Requires `outcome: "pending"`. Returns the refusal without calling `start` when persistence fails. Otherwise calls `start` once and returns `{ kind: "started", audit, value }`. `value` is the callback's return value, including a promise. Callback errors propagate. |
| `cleanup(kind, start)` | Accepts `stop`, `mute` or `teardown`. Attempts a record but calls `start` even when the write fails. Returns the audit result beside the callback value. |
| `close()` | Releases this owner. Its later writes refuse as `writer-closed`. Repeated close changes nothing. |

The writer does not decide whether an action is allowed or whether confirmation is valid. The caller supplies that decision. It must inspect the tagged audit result. A policy answer alone cannot start work.

| Event field | Producer and meaning |
|---|---|
| `kind` | Router: `action`. Tool bridge, chained engine and Accounts Verify: `release`. |
| `gen`, `op` | Non-negative generation and positive operation integers from the owning conversation. They link the decision and later outcome. |
| `tool` | Router's reserved tool id from `Tools.TABLE`. Other names become `unknown`. A release record uses `release`. |
| `args` | Original argument envelope. Values never enter the store. Release metadata uses fields `labels` and `recipients`, never the transferred item. |
| `effect` | Policy's effect, or `null` when a refused call has no classified effect. A release record uses `external`. |
| `decision` | Action: `allow`, `confirm`, `refuse`. Release: `send`, `ask`, `withhold`. |
| `confirmed` | Approval owner's observation: `none`, `physical`, `voice`. It contains no name, transcript or model text. |
| `outcome` | `pending`, `completed`, `failed`, `unknown`, `cancelled`. No executor output or exception body enters it. |
| `capture` | Optional, on an action record of a `vision` tool only: `{box, scale, width, height, bytes, sha256, masks}`, four integers, a positive number, two positive integers, two non-negative integers and a lowercase hex digest. Any other field or value refuses the record as `capture`, so no image byte enters the store ([vision](jarvis-vision.md#release-and-route)). |

Each JSON line adds `time` in UTC. The store uses `audit/<UTC date>.jsonl`. The line ceiling includes its newline. Unknown event fields are not copied.

## Privacy and storage

`Redact.js::argumentsFor` retains only present field names from the trusted tool schema or the release envelope. It replaces every value with `[redacted]`. It copies no unknown property name. This includes paths, URLs, numeric credentials, nested objects and binary data. The audit records that an argument was supplied, not its contents. The API receives no key inventory and does not open Secret Service.

This conservative rule avoids a credential-pattern list. Such a list cannot recognize arbitrary credentials or private file text. Images, audio, transcripts, raw keys and executor outputs do not enter the record. Fixed event metadata and bounded argument names keep encoding bounded. The writer also refuses a line above the plan's ceiling.

State and audit directories use mode 0700. `Private.js::directory` owns that rule, shared with the [tool bridge's runtime directory](jarvis-bridge.md#socket-and-runtime-directory). Daily files use mode 0600, including existing files. Links, non-regular files, hard links and other owners refuse. The directory scan retains only total bytes and the next oldest candidates. It does not retain a list proportional to the number of files.

Before appending, the writer removes expired daily files. The cutoff uses UTC days. With the default setting it retains today and the preceding days inside the retention period. The byte ceiling reserves room for the event and a removal record. Size pruning removes the oldest daily file, including today's file when it alone fills the store. Each removal appends a `prune` record with date, byte count and `age` or `size`. An unexpected filename refuses instead of deleting unrelated data.

The writer flushes each complete append and the audit and state directory entries before the action callback. A short append rolls back to the previous file length and refuses. An incomplete final line refuses subsequent appends. A failure to remove, append, set permissions, flush or close refuses new work. Removal can succeed before its record fails; the returned failure still prevents the requested action. Shutdown remains available.

This is a user record, not tamper evidence. It has no hash chain. Another process running as the user can alter it. Filesystem checks are not protection against a concurrent same-user attacker. [Denied](jarvis-policy-paths.md#real-paths) already refuses VGS state to typed file calls. The planned sandbox must consume its masks so executors cannot write this directory. The audit API does not implement that executor confinement.

## Evidence

`scripts/test-jarvis-redact.js` plants recognizable and arbitrary keys, credential URLs, numeric credentials, private media, nested content and unknown property names. Its controls copy argument values or unknown names into the result.

`scripts/test-jarvis-audit.js` reads actual files before its stand-in action starts. It checks decision and outcome fields, release decisions, daily rollover, permissions, retention boundaries, the actual byte ceiling, shutdown exceptions and writer lifetime. Write and flush fault stand-ins refuse action callbacks. A partial-write case proves rollback and a successful retry. Controls remove independent persistence, ordering, privacy, permissions, retention and lifetime behavior on temporary module copies.

Both suites use the [private Jarvis test world](validation-jarvis.md). They start no executor, network request, authentication, microphone or speaker. [Validation](validation.md) selects both suites from their direct and shared inputs.

The synchronous filesystem contract comes from the [Node 22 filesystem reference](https://nodejs.org/docs/latest-v22.x/api/fs.html). `writeSync` returns the written byte count. Linux append mode writes at the file end. A complete file flush cannot be replaced by a directory flush.

## Omarchy comparison

The read-only Omarchy shell reference at `8b4eae6` keeps agent display in `plugins/agents/Main.qml` and external collectors behind it. That file reads usage snapshots and supplies no action audit gate.

The read-only omarchy-voice reference at `8ef9d60` uses the `Trace` class in its `src/omarchy_voice/trace.py` for one locked, owner-only JSON-lines writer with rotation. VGS keeps one writer and private files. It uses date retention and the plan's total byte ceiling instead of diagnostic backup counts. The `redact_text` function in that reference's `src/omarchy_voice/security.py` matches known key patterns and secret environment values. VGS omits all argument contents because arbitrary secrets have no reliable pattern. Diagnostic logging also does not establish the required refusal before an action.
