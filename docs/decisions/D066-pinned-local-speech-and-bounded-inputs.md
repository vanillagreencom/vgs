# D066: Local speech uses pinned exports, bounded Moonshine inputs and CPU streaming captions

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: VGS-651; [Jarvis research § Local speech stack](../plans/v2-jarvis-plan-research.md#23-local-speech-stack-candidate-set-j38-pins-it-before-any-other-local-issue)

**Context**: The plan's model names did not fix the actual exported files, licences or runtime builds. Parakeet full-buffer caption decoding costs more than the intended update interval. The Moonshine English export returns an empty transcript for the permitted long utterance when sent in one decode.

**Decision**: `shell/plugins/vgs.jarvis/artifacts.json` is the pinned declaration. The independent measurement instrument uses real local files and the bundled synthetic fixture. Moonshine takes bounded independent inputs under [the measured contract](../architecture/jarvis-local.md#moonshine-input-contract). Nemotron's cached streaming export runs on CPU for captions in every selected resident tier. The small tier therefore holds the caption model too. Production registration, adapters, setup and admission remain with their owning issues.

## Reasons and alternatives

- The sherpa Parakeet export uses its encoder, decoder, joiner and tokens. The research's `onnx-asr` export has another layout and does not replace it.
- The measured `30`/`60`-second Parakeet re-decodes take `0.953`/`2.367` seconds on CPU and `0.841`/`1.678` seconds with CUDA requested. Each exceeds the plan's `200` ms caption interval.
- Nemotron's CPU warm full-stream compute takes `3.431`/`6.625` seconds for those inputs. Its longest warm decode calls take `0.07389942201552913`/`0.07672057900344953` seconds. The export uses `560` ms model chunks. Cached streaming avoids repeated full-buffer work. CPU keeps captions available without GPU admission. The model uses OpenMDW-1.1 terms, not Parakeet's CC-BY terms.
- Moonshine's English archive grants MIT terms. The measured input bound is `80000` samples. The `60`-second resident-tier probe decodes all `960000` samples in `12` independent chunks. This establishes execution, not semantic quality across boundaries. Other legacy non-English Moonshine exports have non-commercial terms and are not selected.
- Whisper's pinned SDK discards input beyond its reserved feature-window bound. Independent calls of at most `464000` samples replace the original single-call multilingual probes. [The input contract](../architecture/jarvis-local.md#whisper-input-contract) distinguishes this SDK from OpenAI's sliding-window wrapper. [The corrected evidence](../measurements/jarvis-local-2026-09-30-fix.txt) replaces the incomplete multilingual readings and preserves a reproducible unbounded Moonshine failure.
- Piper LJSpeech medium trains from scratch on public-domain recordings. Its model/voice evidence permits the selected voice. Lessac's recordings have research-only terms. Ryan's recordings have non-commercial terms. A repository-wide MIT label alone is not voice permission.
- The actual wake archive's README declares Apache License 2.0. This closes Q5's missing-licence question. The clip produces no wake hit. The choice establishes execution and licence feasibility only. openWakeWord's pretrained models have non-commercial terms. No commercial subscription wake service is required.
- Kokoro's model and voice table carry Apache terms. The external sherpa runtime also contains espeak-ng under GPL terms. VGS ships neither the runtime nor those model files.
- The measured CUDA build uses the host's CUDA 13 and cuDNN 9 libraries. The manifest pins its actual published wheel, not the shortened missing URL. The native CPU-only runtime is not measured by this run.

## Omarchy comparison

Omarchy's `quattro` reference delegates dictation setup to Voxtype, verifies the selected engine and starts its own service. VGS takes engine verification. It does not add that service, configure input bindings or install anything from this feasibility row. omarchy-voice uses a cloud voice path and has no counterpart for this local artifact inventory. Its fake-frame tests inform test isolation, not actual model evidence.

**Verification**: [The dated measurements](../measurements/jarvis-local-2026-09-30.md) include every artifact and the final resident tiers. `scripts/test-jarvis-local.py` carries contract controls. `scripts/check-jarvis-local.sh` runs actual local inference or returns `77` without prepared inputs.

**Revisit When**: An export, runtime, licence, selected voice or input contract changes; another machine needs different providers; or room/semantic checks require another wake or speech model.

**References**: [Jarvis local inputs](../architecture/jarvis-local.md), [D035](D035-manifest-requirements.md), [upstream segment decoding](https://k2-fsa.github.io/sherpa/onnx/moonshine/models-v2.html), [OpenMDW-1.1](https://openmdw.ai/license/1-1/).
