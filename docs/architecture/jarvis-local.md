# Local speech feasibility inputs

Covers: shell/plugins/vgs.jarvis/artifacts.json, shell/plugins/vgs.jarvis/measure-local, shell/plugins/vgs.jarvis/fixtures/, scripts/check-jarvis-local.sh, scripts/test-jarvis-local.py, scripts/fixtures/jarvis-local/

[D066](../decisions/D066-pinned-local-speech-and-bounded-inputs.md) closes the local stack choices. [The measured run](../measurements/jarvis-local-2026-09-30.md) records execution, load, turn, unload and memory observations.

## Boundary

These feasibility inputs share the Jarvis plugin directory. [The service](jarvis.md) owns registration. [Local setup](jarvis-setup.md) owns installation and readiness. J39 owns production adapters and segmentation. J41 owns admission. J42 owns production captions.

The installed tree carries the pinned declaration, instrument, synthetic fixture and [setup package locks](jarvis-setup.md#inputs-and-boundary). It carries no model, Python environment, CUDA library or espeak runtime. The instrument never installs or downloads anything. Setup verifies its actual selected runtime before publishing readiness.

D035 command requirements live in the plugin manifest. This independent instrument uses Python and uses `nvidia-smi` only for optional CUDA measurement. The [setup contract](jarvis-setup.md) defines the user-started install path.

## Artifact contract

`artifacts.json` owns URLs, revisions, archive and direct-file hashes, software versions, providers, input formats, languages and software/model/voice licence evidence. The CUDA wheel names its actual published build and Python ABI. The shortened wheel URL in the original research does not name that file.

`measure-local::manifest` judges the declaration. `measure-local::verify` checks local archives and direct inputs. It also compares local phonemizer/dictionary bytes with their pinned archives. A missing model or runtime returns `77`. A wrong hash or malformed declaration fails. No probe substitutes another model or provider.

The manifest's tier maps include the resident caption model. A tier's requested CUDA provider applies only to its CUDA-listed artifacts. The record reports each artifact's actual requested provider separately. The instrument's GPU allocation proves a context ran, not that every ONNX graph node ran on CUDA.

`measure-local::PROVIDERS` owns the CLI and declaration vocabulary. Invalid tier providers fail before loading. Valid CUDA tiers retain the declared CPU-only artifacts. A simultaneous sampler failure adds a diagnostic but does not replace the primary inference failure or its status. Sampler-only unavailability returns `77`.

## Moonshine input contract

Upstream [the English export's long-file example](https://k2-fsa.github.io/sherpa/onnx/moonshine/models-v2.html#sherpa-onnx-moonshine-base-en-quantized-2026-02-27-english) uses VAD with offline ASR, not an arbitrary-length single decode. Its [Python API example](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/python-api-examples/offline-moonshine-decode-files-v2.py) creates an independent stream for a wave file. This permits independent segment decoding. It does not promise safe word boundaries or certify a maximum duration.

The measured VGS bound is `80000` mono float32 samples at `16000` Hz, or `5` seconds. J39 must bound every Moonshine SDK input by this value, create a fresh offline stream per chunk, decode every chunk in input order, retain the final shorter chunk and preserve the speech samples. It must join chunk outputs once. An empty or failed chunk must not become a successful final transcript.

The feasibility instrument uses non-overlapping fixed chunks. It is not production VAD segmentation. J39 must choose speech boundaries within the measured bound. J59 owns the semantic-quality and room checks. The raw `60`-second input remains unsupported by this export/runtime pair.

The test-only `scripts/fixtures/jarvis-local/probe-moonshine.py` removes the bound on a disposable artifact declaration and calls the real instrument. [The supplemental log](../measurements/jarvis-local-2026-09-30-fix.txt) preserves its source/runtime binding, command, native broadcast diagnostic and exit. This is separate from the original successful bounded-run log.

## Whisper input contract

[OpenAI's transcribe wrapper](https://github.com/openai/whisper#python-usage) processes a file with sliding windows. The pinned [sherpa-onnx SDK](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/sherpa-onnx/csrc/offline-recognizer-whisper-impl.h) is a lower-level decoder. It clips at `2950` feature frames, reserving `50` of its `3000` frames, and reports that it discards remaining input.

The artifact therefore bounds a single call to `464000` normalized mono samples at `16000` Hz, or `29` seconds. The generic bounded decoder executes independent calls in order and keeps the final shorter segment. A `60`-second input executes segments of `464000`, `464000` and `32000` samples. The completeness control observes a marker emitted only when the later segment is decoded. Submitted sample totals or prefix words cannot satisfy that control. J39 owns production segmentation and reconstruction.

## Fixture outcomes

The paired waveform and original text are synthetic and MIT-licensed. `fixtures/PROVENANCE` identifies generation and resampling. The declaration pins both hashes.

`measure-local::outcome` owns the fixed fixture oracle. It checks transcript words, generated audio rate and duration, speech samples and complete-turn probability. Wake execution needs decoder calls but no hit. These checks prove this fixture executed and produced its known properties. They do not prove semantic transcription quality, other languages, other voices or room accuracy.

## Measurement and validation

The caller supplies local prepared inputs and a scrubbed network namespace. The instrument reads only its bundled audio/text and local models. It never opens capture, playback or authentication. `scripts/check-jarvis-local.sh` runs the actual CPU-model row through [the shared Jarvis world](validation-jarvis.md). Without prepared model/runtime paths it exits `77`, not success.

The runner resolves prepared model and interpreter paths before entering that world. It preserves the interpreter's final symlink so the venv retains its identity.

`scripts/test-jarvis-local.py` tests the actual instrument's declaration, hash, fixture, chunk and output rules. Its disposable copies disable each tested rule. Recognizer and GPU-command doubles test the consumer's API calls, not model feasibility. The actual-model row provides separate execution evidence. [Validation](validation.md) owns row selection.

The same suite drives the real `run.py` consumer with an inference-program double. Separate defects and disposable mutants cover discovery, required membership, child exit, record identity, warm time and wake decode. Those contract tests are not real-model evidence.

Standalone synthesis real-time factor divides warm generation time by generated audio duration. Tier records retain their sequential-compute/input-duration ratio. `rtf_basis` names the denominator.

CUDA memory measurement needs a network-only namespace that preserves this process's host PID. A private PID namespace hides its NVIDIA process identity and cannot provide this reading. CPU behavior tests use the shared environment's private PID namespace.

The instrument requires Python with `hashlib.file_digest`. The measured backend uses the pinned Python ABI. No user setup instructions belong here.
