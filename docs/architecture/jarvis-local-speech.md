# Jarvis local speech

Covers: shell/plugins/vgs.jarvis/backend/LocalSpeech.js, shell/plugins/vgs.jarvis/backend/local-speech.py, scripts/test-jarvis-local-speech.js, scripts/test-jarvis-local-speech.py, scripts/check-jarvis-local-speech.sh, scripts/fixtures/jarvis-local-speech/

The local row of the [chained engine's](jarvis-engine.md) speech table runs speech to text and text to speech on the user's machine. One Python sidecar per conversation loads the tier [local setup](jarvis-setup.md) installed. [D089](../decisions/D089-jarvis-chained-engine-and-heard-prefix.md#refined-by-vgs-652-2026-10-02) records the boundary. [Local inputs](jarvis-local.md) owns the declaration and the measured input bounds this row obeys.

## Boundary

- `LocalSpeech.js` is the row and the adapter. It owns the sidecar process, the wire and the resampling between Audio and the models.
- `local-speech.py` is the sidecar. It owns readiness at load, segmentation, bounded decoding and synthesis.
- Setup's `status` stays the one readiness judge. `measure-local::load` stays the one loader of each pinned export.
- J41 owns admission, residency across conversations and process limits. J42 owns partial captions and turn detection. J44 owns Whisper and a voice per language. This row yields no partial and uses the English exports.

## Selection

`select({directories})` reads the marker setup publishes under the hello's state root. It answers before any account is read.

| Marker | Answer |
|---|---|
| Absent | `speech=local-not-set-up` |
| Unreadable or not JSON | `speech=local-not-ready`, detail the error code or `marker-json` |
| Data root `<data>/local` missing | `speech=local-not-ready`, detail the error code |
| Tier not declared, or `data` not the resolved data root | `speech=local-not-ready`, detail `marker-stale` |
| Otherwise | ready, with one recipient `{kind: "local", provider: "local-speech", account: ""}` |

The marker check is cheap and runs at each snapshot. It is not readiness: the sidecar asks setup's judge before it loads, and a stale runtime fails the first request with `speech=local-runtime-not-ready`. Without setup the stock daemon stays unconfigured.

## Sidecar process

- `open` spawns `unshare --map-current-user --net -- setpriv --pdeathsig KILL -- <data>/local/venv/bin/python -I local-speech.py --state S --data D --parent PID`. The sidecar has loopback only, and the daemon's death kills it. It exits when its parent is not the daemon that started it.
- Its environment is `PATH`, `HOME` and `LC_ALL`. The sidecar sets the model libraries' offline switches itself.
- The sidecar holds setup's lock shared for its lifetime, so setup refuses as busy while a conversation runs. While setup holds the lock, the sidecar refuses with `setup-busy`.
- It loads the marker's tier: one recognizer (Moonshine or Parakeet), Silero and one voice (Piper or Kokoro). A tier with none or two of a role is a defect.
- Models load when the conversation opens and unload when `close()` kills the sidecar at the conversation's end. The sidecar writes nothing under the plugin directory.

## Wire

Frames in both directions: a u32be header length, a u32be payload length, a JSON object header, then the payload. A header is at most 4096 bytes and a payload at most 64 KiB. Audio is float32 little-endian mono. The sidecar's header is the authoritative table.

| Direction | Message |
|---|---|
| in | `audio {id}` + 16 kHz samples; `end {id}`; `abort {id}`; `speak {id}` + the sentence's UTF-8 text |
| out | `ready` once; `final {id, text}`; `audio {id}` + samples; `spoken {id, rate}`; `failed {id?, cause}` |

- Each new request takes a larger id. The sidecar answers in arrival order. A message for an utterance it already answered crossed that answer and is dropped. Any other violation exits 65.
- `failed` without an id ends the sidecar. Exit 77 is not ready.
- The adapter refuses a header of the wrong shape, an id it never issued, an invalid cause or rate and a partial sample. Each ends the sidecar with `speech=local-protocol key=<k> value=<v>`.

## Transcription

1. The adapter resamples Audio's 24 kHz signed 16-bit capture to 16 kHz float samples as frames arrive. A read that splits a sample keeps its first byte for the next read.
2. At capture end the adapter sends `end`. The sidecar runs Silero over the whole utterance and pads each segment by 200 ms within the input.
3. Neighbouring spans share a chunk while it fits the recognizer's `maxInputSamples`. A longer span is cut at the quietest 20 ms frame in the second half of each bound; its final shorter part is the last chunk. Moonshine's inputs therefore stay within `80000` samples, and a bounded export such as Whisper's `464000` keeps its final segment.
4. Each chunk is decoded on a fresh stream, in input order. The texts are joined once, with single spaces.
5. No detected speech is an empty final, and the engine then sends no request. An empty or failed chunk fails the utterance with `chunk-empty index=N` or `chunk-failed index=N`; its neighbours never stand in for it.

Silence between spans that do not share a chunk is not decoded. J59 owns semantic quality across cuts.

## Synthesis

The adapter sends one `speak` per released sentence and waits for its `spoken`. It resamples the voice's rate to Audio's 24 kHz, then yields the sentence's first chunk with `{text, frames}` and the rest as `{pcm}`, each at most 24000 frames. `frames` counts the resampled samples Audio plays. The sidecar sends no word alignment, so Audio credits a sentence only when all of it was heard.

A voice whose rate differs from the declared `outputSampleRate`, an empty or non-finite sentence and a synthesis error fail the sentence.

## Resampling

The adapter's polyphase resampler uses a Blackman-windowed sinc with 64 taps per branch. Its passband ends at 90% of the lower rate's Nyquist frequency, so decimation folds nothing into the speech band. A whole stream of `n` samples yields `ceil(n × to / from)`.

## Bounds

| What | Ceiling | Past it |
|---|---|---|
| One utterance at the sidecar | 120 s, plan § 3.10's highest `maxUtteranceSeconds` | `utterance-too-long` |
| Requests the sidecar has not read | 120 s of 16 kHz float samples | `speech=local-backlog`; the sidecar ends |
| One sentence's synthesized audio | 8 MiB | `speech=local-sentence-audio` |
| One sentence's text | 64 KiB of UTF-8 | `speech=local-sentence-too-long` |
| Sidecar stderr kept for the log | 4 KiB | the oldest bytes drop |

These are allocation and protocol limits, not measured latency budgets.

## Evidence

- `scripts/test-jarvis-local-speech.py` loads the sidecar with recognizer, VAD and voice doubles in the [J09 world](validation-jarvis.md). Its plan table pins the `464000` decoder's segments `464000`, `464000` and `32000`, twelve Moonshine bounds for 60 s, a kept final chunk, merged and separate neighbours and the quiet cut. It covers fresh streams, input order, the single join, empty and failed chunks, the wire and its violations, the utterance bound, readiness, the setup lock, tier roles, the real entry point's exits and the real-model runner with a stand-in interpreter. Each of its 22 controls plants one defect in a copy.
- `scripts/test-jarvis-local-speech.js` installs `fixtures/jarvis-local-speech/standin.py` as the runtime's interpreter. The real spawn, environment, namespace, resampler and wire run against it. The stand-in reports its own network namespace, parent-death signal, argv, environment and received samples. Its 15 controls cover selection, the boundary, resampling, failures, the protocol, abort, backlog, close and sentence frames.
- `scripts/check-jarvis-local-speech.sh` runs the small and medium tiers' real models through the sidecar's segmentation, decoding, synthesis and wire on the bundled clip and a 60 s input. Without `JARVIS_LOCAL_MODELS` and `JARVIS_LOCAL_PYTHON`, or without an input a tier needs, it exits `77`.
- The engine and daemon suites keep their scripted rows. The stock engine answers `speech=local-not-set-up` without reading an account.

## Omarchy comparison

The session that built this row could not read `basecamp/omarchy`; the comparison rests on references other Jarvis docs recorded. Omarchy's `quattro` voice setup delegates dictation to Voxtype and its own service ([D066](../decisions/D066-pinned-local-speech-and-bounded-inputs.md#omarchy-comparison)). VGS keeps setup's verified runtime and runs one sidecar per conversation as the daemon's child, with no service, because the plan allows no capture without an indicator and a unit could outlive it. omarchy-voice speaks through a cloud engine and has no local segmentation to compare.
