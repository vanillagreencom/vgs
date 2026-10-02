# Jarvis chained engine

Covers: shell/plugins/vgs.jarvis/backend/ChainedEngine.js, shell/plugins/vgs.jarvis/backend/jarvisd.js, scripts/test-jarvis-engine.js, scripts/fixtures/jarvis/engine.js, scripts/fixtures/jarvis-brain/openai-chat-frames.js

The chained engine implements the [plan's chained voice](../plans/v2-jarvis-plan.md#35-speech-engines-playback-accounting-latency): speech to text, brain, `Speakable`, text to speech, playback. It connects the existing owners for one conversation at a time. It adds no second queue, player, clock or identity owner. [D089](../decisions/D089-jarvis-chained-engine-and-heard-prefix.md) records the choices.

## Owners

- `ChainedEngine.js::create` owns one conversation's resources: the recipient set, its `net.create` owner, the speech adapter, the wire brain, the grant list, the pending heard prefix and any late tool result. `end()` releases all of them.
- [Session](jarvis-session.md) owns generation and operation identity, deadlines and phases. The runner stamps every engine callback with its effect's identity.
- [Audio](jarvis-audio.md) owns the recorder, the player, pacing and [heard accounting](jarvis-playback.md). The engine supplies the capture sink and the playback source that Audio requests.
- `WireBrain.js` owns history and its [context bound](jarvis-brain.md#bounds). The engine sends turns and keeps no copy of history.
- [ToolRouter](jarvis-approval.md) owns calls, approval, executor starts, taint and every answer item a brain receives for a call. The engine routes the brain's calls and returns the router's results as one tool-results turn.
- [Audit](jarvis-audit.md) records each transfer before it starts. [Policy.release](jarvis-release.md) judges each item against the conversation's whole recipient set.

## Engine seam

The daemon creates the engine with the router and the audit writer on the first hello. It installs this surface, which a later engine shape refines rather than duplicates:

| Member | Session or Audio consumer |
|---|---|
| `configure(settings)` | The daemon, before each snapshot. The gate rises only on `ready`. |
| `observe(state)` | The daemon's publish callback. A generation change ends the conversation. |
| `brain` | Session's brain port: `send`, `cancel`, `close`, and the router's `outcome`. |
| `collect(e, done, failed)` | Session's collect port. |
| `captureSink(e)`, `playbackSource(op)` | Audio's speech sink and source factories. |
| `playback(port)` | Wraps Audio's playback port to read the flush report. |
| `close()` | Lease loss. |

## Selection

`configure` answers `{kind: "ready"}` or `{kind: "unconfigured", cause}`. It never answers with a partial plan.

| Step | Source | Cause when it fails |
|---|---|---|
| Speech | The first ready row of the speech table, in table order | `speech=no-adapter`, or the first row's own cause |
| Brain account | The `brain` setting through `Accounts::resolve`: a keyring reference or a local server, with no vendor command or port read | `brain=unselected`, `brain=account-unavailable`; a keyed account or key reader failure is `brain=accounts-unreadable` with that failure as `detail` |
| Model | The provider declaration's Verify probe model in `AccountProviders.js` | `brain=model-required` |
| Driver and recipient | The `Providers.js` row; its base origin is the brain recipient | A row outside the driver table is an invariant error |
| Guidance class | `local` for a loopback base, else `text` | none |

Any other failure during selection is a defect and throws. The speech table ships empty, so the installed daemon stays unconfigured with `speech=no-adapter`. A speech row is `{select({settings, accounts})}`. A ready answer carries the row's recipient entries and `open({net, recipients})`. The ElevenLabs and local rows extend this table and use the same selection path. Plan § 3.10's `voiceProvider`, when it exists, chooses above this table and above the duplex engine.

## Speech adapter contract

| Member | Contract |
|---|---|
| `transcribe(frames)` | `frames` is an async iterable of `speech`-labelled Policy items holding PCM Buffers. It yields `{kind: "partial", text, rev}` with strictly increasing `rev`, then one `{kind: "final", text}`. `return()` abandons the utterance. |
| `speak(sentences)` | `sentences` is an async iterable of released Policy items holding `Speakable` sentences, with their reply's labels. It yields Audio's object-mode chunks: `{pcm, sentence: {text, frames, words?}}`, then `{pcm}` for the rest of that sentence. It ends when its input ends. |
| `close()` | Releases the adapter's own resources. A network adapter sends only through the `net` owner it received, with the labels of the items it carries. |

A partial only draws: it reaches Session's collecting turn. Only the final reaches the brain. A partial whose revision does not increase, an event of another shape and a transcription that ends without a final are failures. While the capture is open, a failure closes it as `provider-disconnected`. After the capture closed, it reaches the collecting turn as Session's `collect-failed`. An utterance no collection holds reports only an `audio-fault` line.

## Turn loop

1. Audio opens capture and calls the capture sink. The engine releases and audits a `speech` item, then starts `transcribe`. The sink holds one frame until the adapter reads it, so Audio's backpressure reaches the recorder.
2. Session's final becomes `brain-send`. On the conversation's first turn the engine opens the brain with `Guidance.compose("chained", class, language)` and the router's offers. The turn carries the pending heard-prefix item, any late tool result, then the final as a `speech` item.
3. Each response is one `WireBrain.send`. The engine records an `ask` or `withhold` decision, passes the request's labels to the router's taint, then releases and audits the request before its first read.
4. The engine reads the response to its end. Text passes through one `Speakable` stream per response. Each sentence is released and audited before the adapter receives it. The first released sentence dispatches Session's `play` for the brain operation.
5. A `tool-calls` response routes its calls one at a time. Each result returns through the brain port's `outcome`. The engine then sends one tool-results turn. The local class adds `afterToolResult` as its instructions.
6. A `stop` response ends the turn's speech input and dispatches `brain-done`. Speech still waiting on Audio plays on, so Session's thinking deadline bounds the brain and its tools, never speech. The history bound dispatches `brain-ended`, a clean end with the keyed reason. Any other failure dispatches `brain-failed` with the producer's keyed cause, or `engine=unexpected`.

An empty final dispatches `brain-done` without a request.

## Toggle captures

In toggle mode Session reopens capture while the brain thinks, before it collects the next turn. That capture's utterance waits unbound. A new collection adopts it only while it is still transcribing. One that already concluded spoke before the collection existed: the engine abandons it, and the collection's own capture binds instead. A later unbound utterance replaces and abandons an earlier one.

## Barge-in and the heard prefix

Session's `interrupt` cancels the thinking turn and flushes playback. The engine handles both effects:

- `brain-cancel` stops the turn and ends its speech input. A sent request's entry stays in history, unanswered, without its partial reply. Once a reply's calls are in history, every call gets an answer through `WireBrain.record`: its result, the router's `running` answer for the call in flight, or `not-started`. The acknowledgement follows the brain's own cancel acknowledgement. The pending heard prefix starts empty.
- The flush wrapper reads Audio's report. Its `heardText` becomes the heard prefix of the turn whose speech played. A `null` report means nothing was heard.
- Natural completion means the player drained every sentence. It adds no context.

The next user turn starts with one item that carries the reply's labels: `[interrupted] The user heard only this part of your last reply: "<prefix>"`, or `[interrupted] The user heard none of your last reply.` The engine sends it once. History is not rewritten. Session keeps the brain owner after an acknowledged cancel in a live conversation, so the brain keeps its history.

A call answered `running` reports its real outcome later. When the router's result names that call and turn in the same conversation, the next user turn carries `[late result] Your interrupted call <tool> ended <outcome>: <content>`, with the result's labels. A newer conversation never receives it.

## Lifetime and recipients

- A conversation opens at its generation's first capture or brain effect. Its recipient set is the brain row's entry plus the speech row's entries, under the current policy profile.
- `observe(state)` runs on each publication. It ends the conversation when the generation changes: stop, mute, lock, toggle, lease loss or a session-setting change. `end()` cancels and closes the brain, abandons utterances, ends speech, closes the adapter and closes the `net` owner. A late cancel acknowledges after that closure.
- A changed brain, provider, account or policy setting ends the conversation in Session. The next conversation uses the new selection and a new recipient set, so no grant or context crosses to it.
- A brain that Session closes at its cancellation deadline leaves the conversation open. The next turn opens a new brain with fresh history.
- An effect of an older generation, or a conversation that `observe` did not end, is an invariant error.

## Release consent

Asked and withheld items travel as markers, which WireBrain renders. The engine passes its per-conversation grant list to every request and every release it judges. No consent producer exists, so the list stays empty and an asked label reaches the brain only as its marker. The approval surface that asks the user, and its grant producer, are open owner gaps.

A sentence and a request carry the labels their requests sent. Those labels were released to the same set with the same grants, so a refusal there is an invariant error.

## Bounds

| What | Ceiling | Past it |
|---|---|---|
| Playback source | 16 object-mode chunks, below Audio's allowance | The pump waits for Audio to read |
| Released sentence text waiting for synthesis | 8 MiB of UTF-16 code units | `engine=speech-queue` fails the turn |
| Capture held for transcription | 16 KiB writable high-water mark | Audio pauses the recorder |
| Brain response | WireBrain's 8 MiB bound | The response fails |
| History | 40 user turns | `brain-ended` with `brain=context-limit`; the next conversation starts fresh |
| Tool calls per response | The drivers' 16 | The response fails |
| Late tool results | One; the router runs one action at a time | none |

Speech is never dropped: synthesis waits for Audio. These are allocation and protocol limits, not measured latency budgets.

## Boundaries

- No speech row ships. The ElevenLabs and local sidecar rows add theirs. The mapped indicator also gates capture.
- The model setting and its choices do not exist. Selection uses the Verify probe model. Cerebras and the local rows declare none.
- The unconfigured cause is not on the wire. A voice or brain status entry would publish it.
- Older turns are not summarised. The 40-turn bound ends the conversation instead. A summary needs its own model call and release.
- The hello carries no language setting. Empty selects English.
- The local class's restated rule is a system message after tool results. Mistral-family chat templates reject a system message after the first; that matters once a local model can be chosen.

## Evidence

`scripts/test-jarvis-engine.js` runs the real Session, runner, Audio, router, audit writer, release gate, wire brain and `Speakable` in the [J09 world](validation-jarvis.md). Audio's playback clock and the runner's deadline clock are injected. Stand-in recorder and player commands carry PCM. `scripts/fixtures/jarvis/engine.js` supplies the scripted speech row and an OpenAI-compatible loopback brain. The server reads every request body whole and validates it against the pinned excerpt. `openai-chat-frames.js` validates every response frame.

- Cases: partials then final; labelled frames and Speakable sentences to played PCM; barge-in after a completed reply and mid-stream, with the exact heard prefix read at the server and told once; cancel before audio; a tool round with the restated local rule; running and unstarted calls after an interruption, with the late result on the next turn; history taint on a later turn; toggle turns; a transcription failure after capture closed; speech longer than the thinking deadline; conversation end; a setting change; release markers and the audited ask; audit refusal of the request and of speech; the 40-turn bound and the next conversation; playback backpressure; partial revision order; mute during capture.
- The selection table covers each cause, a reader failure's detail and a thrown defect. The stock engine answers `speech=no-adapter` and reads no account.
- Each control plants one defect in a disposable engine copy and must turn an assertion red: six selection rules, router offers omitted, heard prefix omitted or repeated, the full reply reported as heard, no empty prefix on cancel, a partial delivered as final, raw text sent to speech, unlabelled frames, a stale result accepted, interrupted calls left unanswered, a not-started call called running, the late result dropped, history taint not reported, a concluded utterance adopted, a failure after close not reported to the turn, speech gating the brain, the transport left open, no teardown on a generation change, audit skipped, the local rule omitted, a dirty end at the bound, no playback backpressure, revision order ignored and a transcription left running.
- `scripts/test-jarvis-daemon.js` runs a disposable daemon copy with the scripted row, a model for the local brain row and the indicator. The real engine moves the phase through listening, thinking, speaking and idle against the loopback brain. The copy with the stock speech table stays unconfigured.

## Omarchy comparison

The read-only omarchy-voice reference at `8ef9d60` ships two engines. Its realtime engine's `_barge_in` function in the external file `src/omarchy_voice/realtime.py` sizes `audio_end_ms` from the PCM bytes handed to its speaker and sends `conversation.item.truncate`, so the server rewrites the assistant item to what it estimates was heard. VGS differs on both points. A chained brain has no server item to truncate, so VGS adds a separate labelled item instead of rewriting history. The heard text comes from Audio's paced lower bound, not from bytes written, which overstate what the user heard. Its `live.py` engine has no truncation; there a tool interrupted while it runs records `unknown; interrupted while executing`. VGS reports `running`, then the real outcome when it arrives, as plan § 3.4 requires. Its `config.py` keeps `barge_in` off unless echo cancellation exists, and VGS keeps the half-duplex default. The read-only Omarchy shell's agents plugin runs vendor programs and has no voice loop.
