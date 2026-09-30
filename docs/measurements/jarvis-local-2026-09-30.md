# Local speech measurements

Instrument: `shell/plugins/vgs.jarvis/measure-local`. Run: J38, 2026-09-30, from `09:45:56.664616Z` to `09:51:12.882332Z`. [The complete command and result log](jarvis-local-2026-09-30.txt) holds each start/end stamp, exact versions, outputs and unrounded readings.

## Inputs and machine

- Host: `cachy`, AMD Ryzen 9 9950X, NVIDIA GeForce RTX 5090, driver `615.71.09`.
- Backend: sherpa-onnx `1.13.8+cuda13.cudnn9.onnxruntime1.28.2`. CPU rows use its CPU execution provider, not CUDA. The native CPU-only wheel is not measured here.
- smart-turn: ONNX Runtime `1.30.0`, Transformers `5.17.0`. NumPy: `2.5.3`. The feature extractor needs no PyTorch model.
- Input: the pinned synthetic clip and paired text in [artifacts.json](../../shell/plugins/vgs.jarvis/artifacts.json). The short clip contains `43281` mono PCM samples at `16000` Hz, or `2.7050625` seconds.
- Long inputs repeat complete clips. Leading silence fills the remaining samples to the requested length. No last utterance is cut. The text-to-speech input stays the paired original sentence.
- Every child runs in a scrubbed environment under `unshare -rn`. No microphone, playback tool, account or live desktop endpoint participates. Downloads and dependency preparation occur separately.
- Model calls use `2` inference threads. Cold load means fresh model objects with backend-specific first imports. It does not mean an evicted filesystem cache.
- Peak RAM is the process's lifetime `ru_maxrss`, including imports, integrity checks and all resident models. GPU peak is sampled compute allocation for this process. The sampler waits `0.05` seconds between queries; query time adds to the interval. Its reading is a sampled lower bound, not an exact maximum.
- Unload measures model-object destruction and garbage collection. It does not measure process exit. The CUDA contexts still hold `627048448` bytes after large-tier unload and `662700032` bytes after multilingual-CUDA unload. J39 must not equate object destruction with complete process-memory release.

Measured source SHA-256:

| Input | SHA-256 |
|---|---|
| `artifacts.json` | `358ab59c36f7a9f3293af0afa4159bbf37389e6ab40cfdaf6660d67630470881` |
| `measure-local` | `0d3c38980a38b56a13bc8f04396f7549128531babe98f0c27525ac6564806b7c` |
| Raw log | `271c13f81772bfaf2174bdfaf93fd3e04ff47b362262eb9de011a4149d37de94` |

## Bundled-clip execution

All rows below exited `0`. These are execution readings, not language accuracy or voice-quality scores.

| Artifact | Cold load s | First turn s | Warm turn s | Unload s | Peak RAM MiB | Warm real-time factor |
|---|---:|---:|---:|---:|---:|---:|
| Parakeet | 0.796 | 0.103 | 0.097 | 0.032 | 1073.46 | 0.0357 |
| Moonshine | 0.275 | 0.033 | 0.031 | 0.014 | 410.86 | 0.0115 |
| Whisper turbo | 0.717 | 1.047 | 1.015 | 0.036 | 1613.00 | 0.3753 |
| Kokoro | 0.521 | 0.632 | 0.630 | 0.041 | 601.42 | 0.2328 |
| Piper | 0.502 | 0.064 | 0.063 | 0.015 | 229.98 | 0.0231 |
| Silero | 0.020 | 0.010 | 0.006 | 0.005 | 78.55 | 0.0022 |
| smart-turn | 0.452 | 0.045 | 0.053 | 0.048 | 226.66 | 0.0196 |
| Wake model | 0.399 | 0.083 | 0.048 | 0.012 | 93.73 | 0.0179 |
| Nemotron | 0.881 | 0.423 | 0.399 | 0.035 | 1397.90 | 0.1477 |

`measure-local::outcome` checks the fixture's known transcript words, generated audio rate and duration, speech sample count and complete-turn probability. The wake row requires actual streaming decode calls. It permits no keyword hit. This clip produced none. J59 owns room accuracy and reliable wake activation.

## Resident tiers

Each row keeps the tier's entire selected set resident, including CPU Nemotron captions. The manifest owns tier membership and per-artifact providers. The input is `60` seconds. This is total sequential compute, not end-of-speech latency. Streaming caption compute normally happens while audio arrives.

| Tier | Cold load s | First turn s | Warm turn s | Unload s | Peak RAM MiB | Sampled peak GPU MiB | Warm real-time factor |
|---|---:|---:|---:|---:|---:|---:|---:|
| small | 2.249 | 8.219 | 8.123 | 0.063 | 1813.71 | not used | 0.1354 |
| medium | 2.981 | 10.314 | 10.971 | 0.186 | 3303.58 | not used | 0.1829 |
| large | 3.589 | 9.526 | 9.324 | 0.152 | 3782.72 | 4004.00 | 0.1554 |
| multilingual CPU | 3.806 | 14.009 | 14.330 | 0.232 | 5450.77 | not used | 0.2388 |
| multilingual CUDA | 4.426 | 11.499 | 11.317 | 0.152 | 4694.81 | 5976.00 | 0.1886 |

These observations are not admission ceilings or guarantees for other machines, languages or voices. J41 owns live free-memory checks, reserves, fallback and limits.

## Caption cost

Parakeet rows decode the complete buffer once per turn. Nemotron rows decode cached streaming frames. Each row includes a first turn and a warm turn in the raw log.

| Model and provider | Input s | Cold load s | Warm compute s | Unload s | Peak RAM MiB | Sampled peak GPU MiB |
|---|---:|---:|---:|---:|---:|---:|
| Parakeet CPU | 30 | 0.831 | 0.953 | 0.036 | 1585.71 | not used |
| Parakeet CPU | 60 | 0.882 | 2.367 | 0.038 | 2034.80 | not used |
| Parakeet CUDA | 30 | 1.204 | 0.841 | 0.042 | 2259.08 | 1972.00 |
| Parakeet CUDA | 60 | 1.172 | 1.678 | 0.051 | 2428.04 | 2620.00 |
| Nemotron CPU | 30 | 0.999 | 3.431 | 0.042 | 1379.18 | not used |
| Nemotron CPU | 60 | 0.854 | 6.625 | 0.028 | 1118.84 | not used |

Parakeet's full-buffer cost exceeds the plan's `200` ms caption interval. Nemotron's longest warm decode calls were `0.07389942201552913` seconds at `30` seconds and `0.07672057900344953` seconds at `60` seconds. Its export advances in `560` ms model chunks. It is not a `200` ms streaming model. [D066](../decisions/D066-pinned-local-speech-and-bounded-inputs.md) selects it for captions.

## Moonshine bound

The unbounded `60`-second probe failed with an ONNX attention broadcast error, `7 by 2498`, and an empty transcript. Independent chunks of at most `80000` samples close the execution blocker. [The input contract](../architecture/jarvis-local.md#moonshine-input-contract) states what J39 must implement.

- The `30`-second standalone probe decoded `6` chunks. Cold load: `0.296` seconds. Warm compute: `0.395` seconds. Unload: `0.014` seconds. Peak RAM: `410.44` MiB.
- The `60`-second small-tier probe decoded `12` chunks of `80000` samples. It consumed all `960000` samples.
- No test establishes word-boundary reconstruction or semantic transcription quality across those boundaries.
