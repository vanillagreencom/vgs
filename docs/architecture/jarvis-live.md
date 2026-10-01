# Jarvis GPT-Live engine

Covers: shell/plugins/vgs.jarvis/backend/GptLive.js, scripts/test-jarvis-live.js, scripts/fixtures/jarvis-live/, scripts/fixtures/jarvis/websocket.js

`GptLive.js` is the duplex speech engine of [the Jarvis plan § Speech engines](../plans/v2-jarvis-plan.md#35-speech-engines-playback-accounting-latency): one OpenAI GPT-Live session per conversation, its input and output audio and its captions. It implements session lifetime and audio only. Delegation, the brain and commentary belong to J37. No shipped daemon path creates the engine yet.

## Owners

- [Session](jarvis-session.md) owns the lifetime. The snapshot names the daemon's engine, `chained` or `duplex`. With `duplex`, the conversation's first capture emits `speech-open` before `capture-open`, and no utterance is collected: the voice model owns turn-taking. The `speech` region holds the open session and one tagged reply admission, `none` or `waiting`.
- `GptLive.create` owns the provider sessions. A live session holds the net channel, its timers, the opening input buffer, the reply queues and the captions. A closed session finalizes in the background and reaches Session no more.
- [Audio](jarvis-audio.md) owns devices. It calls the engine's `captureSink` and `playbackSource` through the [speech-source contract](jarvis-playback.md#speech-source-contract). The net owner and recipient set belong to the conversation's owner, as for [the wire brain](jarvis-brain.md#owners).
- `Providers.js` holds the `openai-live` row: driver `openai-live`, the WebSocket endpoint, a required key, `store: false` and the retention text.

## Contract

| API | Meaning |
|---|---|
| `create({provider, clock, conversation, captionLimit, log})` | `provider` is the `openai-live` row. `conversation(e)` answers `{net, key, language}` for a `speech-open` effect; `key` is `null` or `{secrets, reference}`. `captionLimit` is the wire's `TRANSCRIPT_CHARS`. `log` takes keyed lines. Returns `{port, captureSink, playbackSource}`. |
| `port.open(e, events)` | Starts a session. `events` are the runner's stamped callbacks: `speak()`, `transcript(record)`, `idle()`, `failed(reason)`. |
| `port.close(e)` | `mode: "graceful"` sends `session.close` and waits for `session.closed`. `mode: "abort"`, on lease loss, releases at once. |
| `port.flush(e)` | Interruption: drops the queued reply and the rest of the interrupted one. |
| `captureSink(e)` | A Writable for the live session's input PCM, or `null` without one. |
| `playbackSource(op)` | The next queued reply of that session as a byte Readable, or `null`. |

The runner turns `speak` into the `speak` event. The reply waits in `speech.reply` until playback is idle, the conversation is active and no talk key is held. Then it takes [half-duplex admission](jarvis-audio-duplex.md#admission-and-resume): capture closes before playback starts, and permitted demand reopens capture after the reply. Captions become the `transcript` effect, which the daemon writes as the [wire's `transcript` message](jarvis-controls.md#wire). Session drops and counts a callback from a closed session.

## Protocol

The engine connects to `wss://api.openai.com/v1/live/sessions` through `net.create(recipients).websocket`, labelled `speech`. It calls `net.assertKeyTarget` first, which binds the key's stored origin to the endpoint's handshake origin. Then it looks the key up through `Secrets.lookup`, when the session first needs it, and zeroes the Buffer once the handshake headers exist. A key stored for the `openai` brain serves both rows, since both handshake at `https://api.openai.com`.

`session.start` carries model `gpt-live-1`, the duplex [voice guidance](jarvis-voice.md), PCM16 at Audio's rate, `delegation: {type: "client"}` and `store: false`. Input audio waits for `session.started`. Every frame leaves through `channel.send`, so the release gate judges each one; an answer other than `send` faults the session.

| Server event | Engine |
|---|---|
| `session.started` | Starts input. A resolved format other than the requested one faults. |
| `session.output_audio.delta` | Strict base64 of whole samples, into the current reply. |
| `session.input_transcript.delta`, `session.output_transcript.delta` | Captions. User speech after an interruption also reopens output. |
| `session.usage.updated`, `info` | Validated and not used. |
| `session.closed` | Finalizes a closing session. While running it faults with its reason. |
| `error` | Faults with the error code. The engine never reads the provider's message text. |
| `session.delegation.created` | Faults `live=delegation-unsupported`. |
| Any other type | Faults with the type. |

A fault names its cause as a keyed reason: `live=server-error code=…`, `live=closed reason=…`, `live=disconnected code=…`, `live=start-timeout`, `live=frame-…`, `net=key-origin`, `live=no-key`. Session takes it as `speech-failed`, and the fault ends the conversation. No other voice takes over.

### Delegation

Client delegation is the documented default, and `null` selects it too, so no session runs without a delegation mode. The engine therefore configures client delegation and refuses every `session.delegation.created` as a keyed fault. It never drops one silently. J37 replaces that refusal: brain and gate run under one `op`, and results go back through `session.commentary.append`.

## Interruption

GPT-Live has no truncate event. On `interrupt`, Session flushes playback and emits `speech-flush`. The engine drops its queued reply and then discards output audio. Input audio advances the session timeline, so the point of the interruption is the input the engine has sent. Output passes again once a user transcript starts at or after that point. By then the server has heard the new speech and handled the interruption. Output that arrives before then belongs to the interrupted reply and never reaches playback.

The primary WebSocket sends no output-audio-done event. A playing reply ends after 500 ms without output. Audio then drains it, and later output starts the next reply.

## Silence, idle and close

While no capture feeds the session, for example after a hold is released, the engine sends paced silence every 100 ms. After a stalled event loop it sends at most 1 s, with no catch-up beyond that. The voice model then hears the turn end and answers.

A session is idle after 60 s with no captions, no output audio and no new capture, while no reply is queued or playing. The engine reports `idle`, and Session ends the conversation and closes the session. A graceful close sends `session.close`, stops input and waits up to 15 s for `session.closed`. A missing answer logs `jarvis: live=close-unconfirmed` with its cause and releases the socket.

## Bounds

| What | Ceiling | Past it |
|---|---|---|
| Connect and `session.started` | 20 s | `live=start-timeout` |
| Opening input before `session.started` | 20 s of PCM | `live=input-overflow` |
| A reply queue | Audio's byte-source high-water mark, `sourceLimit(false, false)` | `live=output-overflow`; the provider cannot be paused |
| Unsent socket bytes | 256 KiB | `live=send-backlog` |
| A server message | 1 MiB | `live=frame-size` |
| A caption segment | the wire's 4096 characters | final, then a new segment |
| Finalizing sessions | 4 | the oldest is released, unconfirmed |

These are recovery bounds and grouping rules, not measured latency budgets. A caption segment also ends final when its speaker resumes 1.2 s or more later on the session timeline; omarchy-voice splits utterances at the same gap. Control characters become spaces.

## Wiring

The daemon still sends `engine: "chained"` and an unconfigured gate. Selecting this engine from `voiceProvider` also needs the conversation's recipient set and key reference, from the voice and account selection, and J16's mapped indicator. The change adds no surface, service or plugin, and the daemon never starts the engine, so no smoke row runs it. `scripts/smoke/rows/jarvis.sh` reads the service's `transcript` status from an instrumented daemon.

## Vendor sources

Read 2026-10-01. `scripts/fixtures/jarvis-live/gpt-live.schema.json` records the reference page's hash.

| Contract | Source |
|---|---|
| Event schemas, endpoint, authentication | [Primary WebSocket reference](https://developers.openai.com/api/reference/resources/live/primary-websocket) |
| Audio formats, `session.started` before audio, close and its 15 s example | [WebSockets](https://developers.openai.com/api/docs/guides/voice-websockets?api=live) |
| Delegation modes, `null` as client, delegation metadata | [Delegation and tools](https://developers.openai.com/api/docs/guides/live-delegation) |
| Transcript timing, idle close, close reasons, errors | [Managing sessions](https://developers.openai.com/api/docs/guides/live-conversations) |
| Playback control belongs to the client | [Server-side controls](https://developers.openai.com/api/docs/guides/voice-server-controls?api=live) |
| Retention | [Your data](https://developers.openai.com/api/docs/guides/your-data): no training use, abuse logs up to 30 days, nothing stored while `store` is false |

## Evidence

- `scripts/test-jarvis-live.js` runs in the [Jarvis test world](validation-jarvis.md). A loopback server built on `scripts/fixtures/jarvis/websocket.js` replays `gpt-live-scripts.json` and validates every frame in both directions against the excerpt. The real engine, Session reducer and runner run with capture and playback ports that follow Audio's contracts, under a manual clock.
- It covers start and the audio round trip, opening input held for `session.started`, paced silence, reply ends, captions through the wire judge, interruption of a playing and of a queued reply, idle close at 60 s, the bounded close wait, lease abort, the finalizing bound, every fault row, the start timeout, a key bound to another origin, a missing key, a withheld frame and each bound.
- One disposable mutant per rule must turn its assertion red: the queue drop, the discard and its timeline point, idle, the close wait, finalizing, each fault, key order and zeroing, opening input, silence, the reply gap, both caption rules, each bound and the release answer.
- [Session evidence](jarvis-session.md#evidence) covers the duplex regions. `scripts/test-jarvis-daemon.js` reads a scripted caption on the daemon's stdout and drops a closed session's caption. `scripts/test-jarvis-protocol.js` pins the `transcript` judge.

## Omarchy comparison

The read-only Omarchy shell has no voice engine; its bar shows the Voxtype dictation state only. omarchy-voice's `live.py` uses the same endpoint, `session.start`, base64 PCM appends, transcript and audio deltas, `session.close` and the 15 s wait. VGS takes those, and its silence while input is gated. It differs: no Responses backend is configured, a delegation is refused rather than handled, any `error` ends the session, and interruption discards by the session timeline. Keys come from libsecret through the origin-bound door.
