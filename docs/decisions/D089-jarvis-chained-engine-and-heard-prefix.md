# D089: Jarvis speech engines: the chained engine owns one conversation's turn loop and tells the brain the heard prefix

[← Decision Index](INDEX.md)

**Date**: 2026-10-01
**Status**: Active
**Research**: [Jarvis plan § Speech engines](../plans/v2-jarvis-plan.md#35-speech-engines-playback-accounting-latency), [§ 3.4 State](../plans/v2-jarvis-plan.md#34-state), [§ 3.11 Bounds](../plans/v2-jarvis-plan.md#311-bounds)
**Refines**: [D084](D084-duplex-speech-engine-sessions.md)

**Context**: The plan needs a chained engine: speech to text, brain, `Speakable`, text to speech, playback. Session owns identity and deadlines. Audio owns pacing and a conservative heard-frame account. WireBrain owns history. ToolRouter owns calls and approval. `Policy.release` and Audit gate transfers. No owner connected them for a conversation, and no owner told the brain what the user heard after an interruption. A chained engine has no provider-side truncation.

**Decision**: `ChainedEngine.js` is the one per-conversation owner between those owners.

- It holds the recipient set, its `net.create` owner, the speech adapter, the wire brain, the release-grant list and the pending heard prefix. It ends all of them when Session's generation changes. It adds no queue, player, clock or identity of its own.
- A speech adapter is a table row. `transcribe(frames)` takes `speech`-labelled PCM items and yields partials with rising revisions and one final. `speak(sentences)` takes released, labelled sentence items and yields Audio's object-mode PCM chunks with sentence sample counts. The table ships empty, so the daemon stays unconfigured with `speech=no-adapter`.
- The brain comes from the saved Brain account through `Accounts::resolve`, the declaration's Verify probe model, the provider table and the key reference.
- Only the final transcript reaches the brain. Only `Speakable` sentences reach text to speech. Every utterance, brain request and sentence passes `Policy.release` against the whole set and `Audit.before`; a refusal or a failed audit write stops the transfer. Each request's labels reach the router's taint, so history from an earlier turn taints the live one.
- After a barge-in, the next user turn starts once with a separate labelled item that carries the prefix Audio reports as heard. A sent, cancelled turn stays in history unanswered, without its partial reply. Interrupted calls are answered `running` or `not-started` in the router's result shape; a running call's real outcome reaches the next user turn of the same conversation. Session keeps the brain after an acknowledged cancel in a live conversation.
- The engine reads each brain response to its end; synthesis alone waits on Audio's bounded source. Session's thinking deadline therefore bounds the brain and its tools, not speech. Speech is never dropped.
- History is bounded at the plan's 40 user turns; past it the brain ends the conversation cleanly with `brain=context-limit`, and the next conversation starts fresh. A transcription that fails after its capture closed ends its collecting turn with a fault.

**Rationale**:
- One owner per conversation releases every resource of that lifetime together, so a provider, account or policy change cannot carry context or grants to a new recipient set.
- Audio's flush report is the only heard account; a second estimate in the engine could disagree with it.
- A labelled item keeps history true: the brain sees what it said and, separately, what the user heard.
- Recording the sent turn and answering interrupted calls keeps every later request valid for both wire drivers.
- omarchy-voice's realtime engine truncates the server's assistant item at a length sized from bytes written. A chained brain has no server item, and bytes written overstate what was heard, so VGS tells the brain Audio's lower bound as a separate item. Its live engine keeps barge-in off without echo cancellation; VGS keeps the half-duplex default. [jarvis-engine.md](../architecture/jarvis-engine.md#omarchy-comparison) states the rest.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Rewrite the assistant reply in history to the heard text | Silent history rewriting; the brain could not tell a cut reply from a complete one. |
| Drop a cancelled turn and resend its items with the next utterance | Fails for tool-results turns, whose pending calls must be answered before a user turn. |
| A playback queue or heard estimate in the engine | Audio already owns pacing and the conservative account. |
| Treat Audio's natural-completion lower bound as the heard text | The player drained every sentence; a shorter prefix would tell the brain the user missed words they heard. |
| Close the brain after every acknowledged cancel | Each barge-in would lose the conversation's history. |
| Truncate the reply at a length sized from bytes written, as omarchy-voice's realtime engine does | No server item exists to truncate, and bytes written exceed what was heard. |
| Stop reading the brain while playback is full | The turn stays thinking while speech plays, so a long reply hits the thinking deadline. |
| Answer every interrupted call "unknown" | Plan § 3.4 tells the brain the real outcome; a call that never started did nothing. |
| Drop the oldest turns at the 40-turn bound | Silent context loss; a summary needs its own model call and release design. |
| A fault at the 40-turn bound | The fault would block every later conversation until a setting changes. |

**Boundaries**: [D084](D084-duplex-speech-engine-sessions.md) owns the duplex GPT-Live lifetime and Session's speech port. This record adds the chained turn loop alongside it. J34 adds acknowledgements and earcons, J35 the ElevenLabs speech row, and J39 the local speech row; each refines this record. J16 owns the mapped indicator. J27 or a later row owns the model choice; Cerebras and the local servers declare no default model. No consent surface produces release grants, so asked items travel as markers. The unconfigured cause is not on the wire. Older turns are not summarised.

**Revisit When**: A speech provider reports played-frame timing, a brain offers its own truncation, or the context bound needs a summary.

**Verification**: `scripts/test-jarvis-engine.js` runs scripted adapters and an OpenAI-compatible loopback brain through the real Session, runner, Audio, router and audit writer, with a disposable mutant per rule. `scripts/test-jarvis-daemon.js` moves an instrumented daemon through listening, thinking, speaking and idle and keeps the stock daemon unconfigured. `scripts/test-jarvis-brain-openai.js`, `scripts/test-jarvis-brain-anthropic.js`, `scripts/test-jarvis-session.js`, `scripts/test-jarvis-session-runner.js`, `scripts/test-jarvis-router.js`, `scripts/test-jarvis-accounts.js` and `scripts/test-jarvis-providers.js` cover the changed owners.

**References**: [Jarvis chained engine](../architecture/jarvis-engine.md), [wire brain](../architecture/jarvis-brain.md), [playback](../architecture/jarvis-playback.md), [D079](D079-brains-wire-and-harness-adapters.md), [D082](D082-jarvis-approval-bound-to-the-action.md).
