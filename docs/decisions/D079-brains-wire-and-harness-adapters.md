# D079: Jarvis brains are wire and harness adapters without an npm dependency

[← Decision Index](INDEX.md)

**Date**: 2026-09-30
**Status**: Active
**Research**: [Jarvis plan § Brain adapters](../plans/v2-jarvis-plan.md#36-brain-adapters), [§ 2.4 subscriptions](../plans/v2-jarvis-plan-research.md#24-inference-what-may-run-on-a-subscription)
**Refines**: [D009](D009-one-manifest-judge-under-node.md), [D046](D046-slack-tokens-per-workspace-and-one-card-per-message.md)

**Context**: Jarvis thinks on a model account the user already has. An account is an API key, a local server or a vendor subscription. Vendor terms allow a subscription only through the vendor's unmodified program; Anthropic forbids routing plan credentials elsewhere. VGS ships no npm tree, and the install tree and its four package channels have no route for one. Ten providers speak one HTTP wire, OpenAI's Chat Completions.

**Decision**: A brain is one of two adapter kinds behind the plan's interface: `start`, `send` as a stream of text, tool calls and done, `cancel` with an acknowledgement, and `close`.

- A wire adapter speaks a vendor's HTTP API with Node's global `fetch` through `net.js`. Its key comes from libsecret and is bound to its origin. Its wire contract is a pinned excerpt of the vendor's published schema, and its tests replay scripts validated against that excerpt.
- A harness adapter starts the vendor's own program, which owns its login. A subscription runs only that way. Jarvis never opens a vendor credential file, copies a login token or offers a vendor sign-in.
- A harness program's own tools are off, and the [tool bridge](../architecture/jarvis-bridge.md) is its only tool server, so every call it makes reaches the router. The adapter verifies that from the program's own report of its tools and refuses the brain otherwise. Claude Code runs in print mode with stream-json, `--tools ""`, `--strict-mcp-config` and its hooks off, one process per conversation ([jarvis-claude.md](../architecture/jarvis-claude.md)).
- Account Verify for a subscription is one tool-less harness turn through that adapter, released and audited like the API probe.
- One provider table, `Providers.js`, holds a row per provider: driver, base URL, key need, image input, no-store request fields and documented retention. One OpenAI-compatible Chat Completions driver serves every row that speaks that wire. Every wire adapter reuses one bounded event stream reader, `Sse.js`.
- No adapter depends on an npm package or a vendor SDK.
- A harness adapter's wire contract is an excerpt of the schema the vendor's program generates, pinned by version and file hash, and its tests replay a stub built from that excerpt. The program's own tools are switched off, or each operation it asks approval for reaches the action router as an approval of a harness row, never offered to a brain. The adapter hands the program only released text. The Codex app-server harness is the first ([jarvis-codex.md](../architecture/jarvis-codex.md)).

**Rationale**:
- One driver for the compatible wire keeps stream parsing, tool-call assembly and release in one place for ten providers. A driver per vendor would repeat them.
- Chat Completions is the wire every row implements. OpenAI's newer Responses API is OpenAI's alone.
- A schema excerpt pinned by commit and file hash lets tests prove request and response shapes without a network or a real key.
- Harness adapters keep subscriptions inside each vendor's terms. The harness rule in the plan keeps their tools behind the policy gate.
- Omarchy runs vendor agents as terminal programs and has no model client. omarchy-voice posts to OpenAI alone with a key from an environment file. VGS takes its refused redirects and unread error bodies, and differs as [jarvis-brain.md](../architecture/jarvis-brain.md#omarchy-comparison) states.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Vendor npm SDKs | VGS ships no npm tree and has no install route for one ([review finding 21](../plans/v2-jarvis-plan-review.md)). The Claude path must stay the unmodified program. |
| Claude Code's permission prompt tool asking Policy for each built-in operation | A built-in tool takes a program, path or URL that Policy cannot classify from its arguments, and the bridge already carries every typed tool. Off is the simpler rule to verify. |
| A Claude Code process per turn, resumed by session id | Resuming needs session files in the account directory, which keep conversation text outside Jarvis's retention settings. |
| A subscription token read from a vendor's credential files | Vendor terms forbid it, and it copies a credential Jarvis does not own. |
| One adapter per OpenAI-compatible vendor | Each would repeat the stream reader, tool assembly, release and bounds. |
| The OpenAI Responses API for the OpenAI row | Only OpenAI serves it; a second driver would serve one row. |
| Yield tool calls as fragments arrive | A lost chunk would yield a partial call to the policy gate. |
| Leave Codex's built-in tools on inside its own sandbox | Its known-safe commands run without asking and read any file Denied protects; the gate would never see them. |
| Answer a harness program's approvals in the adapter | A second judge beside Policy; the router's approval, taint and audit would not apply. |

**Boundaries**: J25 lands the wire driver, the table and the reader. J26 adds the Anthropic Messages driver and its rows. J29 adds the Claude Code harness and its subscription Verify; J31 adds the Codex app-server harness, its approval gate and Codex Verify; J30 adds the ACP harness and refines this record. J27 chooses accounts and publishes model choices. J33 connects a brain to the session's ports; the chained engine selects the Codex harness and not yet the Claude Code harness.

**Revisit When**: A provider the table needs speaks neither a compatible wire nor a harness program, VGS gains an npm install route, or a vendor permits a subscription outside its own program.

**Verification**: `scripts/test-jarvis-brain-openai.js` replays the pinned scripts on loopback inside the Jarvis test world, with a disposable mutant per rule. `scripts/test-jarvis-claude.js` replays a stand-in `claude` against a stream-json excerpt and carries a scripted call through the real bridge and router; a mutant that leaves built-in tools on turns it red. `scripts/test-jarvis-codex-protocol.js` and `scripts/test-jarvis-codex.js` cover the Codex judge against its generated-schema excerpt and recording, and the harness against a stub program with the real gate. `scripts/test-jarvis-providers.js`, `scripts/test-jarvis-sse.js` and `scripts/test-schema-check.js` cover the table, the reader and the schema checker.

**References**: [Jarvis wire brain](../architecture/jarvis-brain.md), [Claude Code harness](../architecture/jarvis-claude.md), [Jarvis Codex harness](../architecture/jarvis-codex.md), [release and network](../architecture/jarvis-release.md), [D073](D073-jarvis-release-and-origin-bound-keys.md).
