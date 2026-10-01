# Jarvis playback

Covers: shell/plugins/vgs.jarvis/backend/Audio.js, scripts/test-jarvis-playback.js, scripts/test-jarvis-playback-pipewire.js, scripts/fixtures/jarvis/playback*

`Audio` owns playback within the [audio lifetime](jarvis-audio.md). It implements the [Jarvis plan § 3.5](../plans/v2-jarvis-plan.md#35-speech-engines-playback-accounting-latency). No second player, queue owner or release path exists.

## Pacing and interruption

- The writer uses the constructor's monotonic clock. It submits complete PCM frames in packets no longer than the requested node latency. Its scheduled frontier stays within the plan's lead. After a provider pause, blocked pipe or delayed event loop, it starts from the current time instead of sending a catch-up burst.
- The source remains in pull mode. The writer holds one bounded chunk and reads no next chunk while it waits on the clock or the player's drain. Source high-water marks share the plan's playback-queue ceiling, with room for the active chunk and a producer's last chunk. A Duplex source shares that allowance across its readable and writable queues. Producers must obey `push` or `write` backpressure. A source that exceeds the allowance faults instead of dropping speech.
- `Audio.teardown` stops writes before it closes the child lease and destroys stdin. It clears the pacing timer, removes input or drain waiters and destroys the source. The PID namespace ends `pw-cat` without draining. Only natural completion calls stdin's `end` and waits for the player's successful close.
- Startup installs its operation before the first asynchronous wait. An interrupt can retire it before a source or child exists. A source acquired during a synchronous provider callback still goes through teardown. An old provider's error cannot release a new operation.

The lead, queue allowance and requested node latency are design constraints from the plan, not measured latency budgets. `Audio.js` owns their constants. [pw-cat](https://docs.pipewire.org/page_man_pw-cat_1.html) defines raw PCM and node latency. [Node streams](https://nodejs.org/docs/latest-v22.x/api/stream.html) defines pull mode, high-water marks, drain and destructive close.

## Speech-source contract

`playbackSource(source)` returns a Node `Readable` owned by Audio. It emits mono signed 16-bit PCM at the audio owner's sample rate. It retains the default close notification. It uses no text encoding.

| Chunk | Meaning |
|---|---|
| `Buffer` | Complete PCM samples with no transcript accounting. Byte streams can span bounded reads. |
| `{ pcm: Buffer }` in object mode | One bounded PCM chunk with no new sentence. |
| `{ pcm: Buffer, sentence: { text, frames, words? } }` in object mode | Begins one sentence. `frames` is its complete sample count, including later chunks. Another sentence starts only after this count is received. |
| `words: [{ frame, end }]` | Actual provider alignment. Each `frame` is the sentence-relative sample count at a complete word's end. Each `end` is its exclusive UTF-16 text offset at a whitespace boundary or the sentence end. Both increase strictly. The last entry covers the whole sentence. |
| Omitted `words` | Credits only the whole sentence when its final frame is in the heard lower bound. Audio never invents word timing from text length. |

Audio inserts a space between sentence texts. It bounds retained text and alignment entries. Invalid PCM, oversized object-mode chunks or source queues, invalid alignment, overlapping sentences and premature sentence EOF fail playback. These refusals serve the planned chained and duplex speech producers.

## Heard-prefix reports

`playbackPort.start(effect, done, failed)` sends an immutable report to `done` after natural completion. `playbackPort.flush(effect, done)` sends the interruption report after release. Flush uses the reducer's `gen` and `target` to select the originating playback operation. A flush with no matching account returns `null`.

| Report field | Meaning |
|---|---|
| `gen`, `op`, `source` | The originating playback effect and speech source. |
| `writtenFrames` | Samples submitted to the player pipe, including Node's bounded pending writes. Never samples received from the provider. |
| `heardFrames` | Nonnegative written frames minus the full lead and requested node latency. This is a conservative software account, not a device's played-frame counter. |
| `heardText` | Transcript prefix ending at the last supplied word boundary within `heardFrames`. It can be empty even when PCM was submitted. |

Teardown freezes the account before waiting for child closure. A later clock tick cannot extend an interrupted prefix. Natural EOF does not promote buffered or received frames to heard frames. The Session runner retains its existing acknowledgment events and ignores extra callback arguments. The planned chained engine wraps these callbacks to tell its brain the heard prefix. [The GPT-Live engine](jarvis-live.md#interruption) supplies byte sources and discards its own pending PCM on flush. `sourceLimit` exports the high-water mark a source may declare; a producer that cannot pause its provider sizes its queue by it.

## Evidence

- `scripts/test-jarvis-playback.js` drives production Audio ports through the synthetic audio world. Its manual clock pins the initial lead, the next packet deadline and the absence of a catch-up burst. Independent expected values pin lead and node subtraction, aligned word rounding and sentence-only accounting.
- The same suite reaches actual child-pipe backpressure. It interrupts waits on input, pacing and drain. It covers startup interruption, provider failure during startup and feeding, source-factory interruption, malformed or oversized PCM and metadata, natural completion and successive operations. Its controls break pacing, accounting, bounds, waiter cancellation, EOF and startup retirement.
- `scripts/test-jarvis-playback-pipewire.js` uses the [private Jarvis world](validation-jarvis.md) and a scratch-only PipeWire configuration. The server loads no hardware factory, session manager, real-time broker or external command. The test checks its node inventory, links the player to a null sink and records that sink's monitor. It requires actual nonzero PCM before interruption and checks both the post-interrupt sample count and the last audible delivery time against the plan's lead plus the private graph period. The recorder runs with unbuffered stdout so its timestamps do not include a later stdio block flush. The test does not use submitted bytes or process exit as audio evidence.
- The private test's controls keep playback running after flush and replace playback PCM with silence. The first exceeds the post-interrupt audio bound. The second cannot satisfy the actual-audio floor. Missing tools or namespaces return 77, never pass.

## Omarchy comparison

The read-only `omarchy-voice` reference's `LiveSpeaker` uses `pw-cat`, a paced PCM pump and a bounded jitter buffer. It clears PCM and ends the player on interruption. Audio keeps those interfaces and avoids catch-up bursts. It uses the plan's shorter lead, propagates source backpressure instead of raising a queue-overflow error on normal producer demand, and reports only supplied word or sentence boundaries. The Omarchy shell's audio panel owns desktop device choices, not heard-prefix accounting. Audio continues to target its own stream without changing desktop defaults.
