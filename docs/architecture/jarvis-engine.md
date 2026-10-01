# Jarvis chained engine

Covers: shell/plugins/vgs.jarvis/backend/ChainedEngine.js, shell/plugins/vgs.jarvis/backend/jarvisd.js, scripts/test-jarvis-engine.js, scripts/fixtures/jarvis/engine.js, scripts/fixtures/jarvis-brain/openai-chat-frames.js

The chained engine implements the [plan's chained voice](../plans/v2-jarvis-plan.md#35-speech-engines-playback-accounting-latency): speech to text, brain, `Speakable`, text to speech, playback. It connects the existing owners for one conversation at a time. It adds no second queue, player, clock or identity owner.

## Owners

- `ChainedEngine.js::create` owns one conversation's resources: the recipient set, its `net.create` owner, the speech adapter, the wire brain, the grant list and the pending heard prefix. `end()` releases all of them.
- [Session](jarvis-session.md) owns generation and operation identity, deadlines and phases. The runner stamps every engine callback with its effect's identity.
- [Audio](jarvis-audio.md) owns the recorder, the player, pacing and [heard accounting](jarvis-playback.md). The engine supplies the capture sink and the playback source that Audio requests.
- `WireBrain.js` owns history and its [context bound](jarvis-brain.md#bounds). The engine sends turns and keeps no copy of history.
- [ToolRouter](jarvis-approval.md) owns calls, approval and executor starts. The engine routes the brain's calls and returns the router's results as one tool-results turn.
- [Audit](jarvis-audit.md) records each transfer before it starts. [Policy.release](jarvis-release.md) judges each item against the conversation's whole recipient set.

The daemon creates the engine with the router and the audit writer on the first hello. It installs the engine's brain port, collect port, capture sink, playback source and flush wrapper. It calls `configure(settings)` before each snapshot and raises the gate only on `ready`.

## Selection

`configure` answers `{kind: "ready"}` or `{kind: "unconfigured", cause}` with a keyed cause. It never answers with a partial plan.

| Step | Source | Cause when it fails |
|---|---|---|
| Speech | The first ready row of the speech table, in table order | `speech=no-adapter`, or the first row's own cause |
| Brain account | The `brain` setting through `Accounts::resolve`: a keyring reference or a local server, with no vendor command or port read | `brain=unselected`, `brain=account-unavailable`, `brain=accounts-unreadable` |
| Model | The provider declaration's default model in `AccountProviders.js` | `brain=model-required` |
| Driver and recipient | The `Providers.js` row; its base origin is the brain recipient | A row outside the driver table is an invariant error |
| Guidance class | `local` for a loopback base, else `text` | none |

The speech table ships empty, so the installed daemon stays unconfigured with `speech=no-adapter`. A speech row is `{select({settings, accounts})}`. A ready answer carries the row's recipient entries and `open({net, recipients})`. The ElevenLabs and local rows extend this table and use the same selection path. Cerebras and the local rows declare no default model, so they need the model choice that does not exist yet.

## Speech adapter contract

| Member | Contract |
|---|---|
| `transcribe(frames)` | `frames` is an async iterable of PCM Buffers from the capture sink. It yields `{kind: "partial", text, rev}` with strictly increasing `rev`, then one `{kind: "final", text}`. `return()` abandons the utterance. |
| `speak(sentences)` | `sentences` is an async iterable of released `Speakable` sentences. It yields Audio's object-mode chunks: `{pcm, sentence: {text, frames, words?}}`, then `{pcm}` for the rest of that sentence. It ends when its input ends. |
| `close()` | Releases the adapter's own resources. A network adapter sends only through the `net` owner it received. |

A partial only draws: it reaches Session's collecting turn. Only the final reaches the brain. A partial whose revision does not increase, an event of another shape and a transcription that ends without a final fail the capture as `provider-disconnected`. A failure after the capture closed reaches the service as an `audio-fault` line.

## Turn loop

1. Audio opens capture and calls the capture sink. The engine audits a `speech` release and starts `transcribe`. The sink holds one frame until the adapter reads it, so Audio's backpressure reaches the recorder.
2. Session's final becomes `brain-send`. On the conversation's first turn the engine opens the brain with `Guidance.compose("chained", class, language)` and the router's offers. The turn carries the pending heard-prefix item, then the final as a `speech` item.
3. Each response is one `WireBrain.send`. The engine records an `ask` or `withhold` decision, then audits the request before its first read.
4. Text passes through one `Speakable` stream per response. Each sentence passes `Policy.release` and `Audit.before` before the speech adapter receives it. The first released sentence dispatches Session's `play` for the brain operation.
5. A `tool-calls` response routes its calls one at a time. Each result returns through the brain port's `outcome`. The engine then sends one tool-results turn. The local class adds `afterToolResult` as its instructions.
6. A `stop` response ends the turn's speech input and dispatches `brain-done`. A failure dispatches `brain-failed` with the producer's keyed cause, or `engine=unexpected`.

An empty final dispatches `brain-done` without a request.

## Barge-in and the heard prefix

Session's `interrupt` cancels the thinking turn and flushes playback. The engine handles both effects:

- `brain-cancel` stops the turn and ends its speech input. A sent request's entry stays in history, unanswered, without its partial reply. Calls that were routing get their results, or `{"kind":"interrupted","outcome":"unknown"}`, through `WireBrain.record`. The acknowledgement follows the brain's own cancel acknowledgement. The pending heard prefix starts empty.
- The flush wrapper reads Audio's report. Its `heardText` becomes the heard prefix of the turn whose speech played. A `null` report means nothing was heard.
- Natural completion means the player drained every sentence. It adds no context.

The next user turn starts with one item that carries the reply's labels: `[interrupted] The user heard only this part of your last reply: "<prefix>"`, or `[interrupted] The user heard none of your last reply.` History is not rewritten. Session keeps the brain owner after an acknowledged cancel in a live conversation, so the brain keeps its history.

## Lifetime and recipients

- A conversation opens at its generation's first capture or brain effect. Its recipient set is the brain row's entry plus the speech row's entries, under the current policy profile.
- `observe(state)` runs on each publication. It ends the conversation when the generation changes: stop, mute, lock, toggle, lease loss or a session-setting change. `end()` cancels and closes the brain, aborts transcriptions, ends speech, closes the adapter and closes the `net` owner. A late cancel acknowledges after that closure.
- A changed brain, provider, account or policy setting ends the conversation in Session. The next conversation uses the new selection and a new recipient set, so no grant or context crosses to it.
- A brain that Session closes at its cancellation deadline leaves the conversation open. The next turn opens a new brain with fresh history.
- An effect of an older generation, or a conversation that `observe` did not end, is an invariant error.

## Release consent

Asked and withheld items travel as markers, which WireBrain renders. The engine passes its per-conversation grant list to every request and every speech release. No consent producer exists, so the list stays empty and an asked label reaches the brain only as its marker. The approval surface that asks the user, and its grant producer, are open owner gaps.

A sentence carries the labels its turn's requests sent. Those labels were released to the same set with the same grants, so a refusal of a sentence is an invariant error.

## Bounds

| What | Ceiling | Past it |
|---|---|---|
| Playback source | 16 object-mode chunks, below Audio's allowance | The pump waits for Audio to read |
| Released sentences waiting for synthesis | 2 | The brain stream is not read further |
| Capture held for transcription | 16 KiB writable high-water mark | Audio pauses the recorder |
| Brain text not yet read | WireBrain's 8 MiB response bound | The response fails |
| History | 40 user turns | `brain=context-limit` ends the conversation |
| Tool calls per response | WireBrain's 16 | The response fails |

Speech is never dropped: each stage waits for the next. These are allocation and protocol limits, not measured latency budgets.

## Boundaries

- No speech row ships. The ElevenLabs and local sidecar rows add theirs. The mapped indicator also gates capture.
- The model setting and its choices do not exist. Selection uses the declared default model.
- The unconfigured cause is not on the wire. A voice or brain status entry would publish it.
- Older turns are not summarised. The 40-turn bound refuses instead. A summary needs its own model call and release.
- The hello carries no language setting. Empty selects English.

## Evidence

`scripts/test-jarvis-engine.js` runs the real Session, runner, Audio, router, audit writer, release gate, wire brain and `Speakable` in the [J09 world](validation-jarvis.md). Audio's playback clock is injected, and stand-in recorder and player commands carry PCM. `scripts/fixtures/jarvis/engine.js` supplies the scripted speech row and an OpenAI-compatible loopback brain. The server reads every request body whole and validates it against the pinned excerpt. `openai-chat-frames.js` validates every response frame.

- Cases: partials then final; Speakable sentences to played PCM; barge-in after a completed reply and mid-stream, with the exact heard prefix read at the server; cancel before audio; a tool round with the restated local rule; a stale tool outcome after an interruption; conversation end; a setting change; release markers and the audited ask; audit refusal of the request and of speech; the 40-turn bound; playback backpressure; partial revision order; mute during capture.
- The selection table covers each cause. The stock engine answers `speech=no-adapter` and reads no account.
- Controls plant one defect each in a disposable engine copy: heard prefix omitted, the full reply reported as heard, no empty prefix on cancel, a partial delivered as final, raw text sent to speech, a stale result accepted, interrupted calls left unanswered, the transport left open, no teardown on a generation change, audit skipped, the local rule omitted, no playback backpressure, no brain pause, revision order ignored, a transcription left running, and three selection refusals removed.
- `scripts/test-jarvis-daemon.js` runs a disposable daemon copy with the scripted row, a model for the local brain row and the indicator. The real engine moves the phase through listening, thinking, speaking and idle against the loopback brain. The copy with the stock speech table stays unconfigured.

## Omarchy comparison

The read-only omarchy-voice reference at `8ef9d60` uses OpenAI's realtime session in `src/omarchy_voice/live.py`. The provider owns turn-taking and truncates its own reply. On a stop, `speaker.interrupt()` clears playback, and a tool interrupted while it runs records `unknown; interrupted while executing`. Its `config.py` keeps `barge_in` off unless echo cancellation exists. VGS takes the unknown outcome for an interrupted call and the half-duplex default. A chained engine has no provider-side truncation, so VGS tells the brain the heard prefix as a labelled item from paced accounting. The read-only Omarchy shell's agents plugin runs vendor programs and has no voice loop.
