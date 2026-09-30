# Shader measurements

Covers: scripts/measure-shader.sh, scripts/shader/**, scripts/test-measure-shader.py, scripts/smoke/rows/shader-frames.sh, scripts/smoke/fixtures/plugins/acme.layers/**

The instrument measures the generic passive visual, not a voice service. [D060](../decisions/D060-passive-voice-orb.md) owns its boundary. The Qt timing facts are in [runtime-qml-shaders.md § Frame timing](runtime-qml-shaders.md#frame-timing).

## Readings

`scripts/measure-shader.sh` uses the existing nested sandbox without starting the product shell or plugin services. It starts one standalone layer at each output scale. Each scene starts after the output takes its scale. The off scene keeps the same background and animation. Only its shader is hidden.

| Reading | Source | Meaning |
|---|---|---|
| CPU sync and render | `qt.scenegraph.time.renderloop`, filtered by the layer's own window address | CPU submission work, in integer milliseconds |
| GPU cost | GPU timestamp frame time with the shader on minus the off baseline, paired by sample index | Incremental GPU frame cost at requested swap interval 0 |
| Presentation | The layer's own `frameSwapped` interval, read in the GUI thread | Compositor-paced presentation, not GPU execution |

Each stream discards 120 warmup readings and keeps 600 samples. Missing, empty or incomplete streams fail. The reader refuses a wrong window, scale, selected device or swap interval. A software device exits 77. The Vulkan backend supplies device identity and GPU timestamps; absent GPU timestamps fail rather than substituting presentation intervals.

The instrument compiles a disposable shader with a 256-step dependent loop. The costly shader must exceed the GPU ceiling at both scales. A CPU scheduling delay or a slow presentation alone does not satisfy that control. `scripts/test-measure-shader.py` covers attribution, missing samples, software refusal, separate readings and each ceiling. Its disposable sample-guard and ceiling-guard mutations turn their tests red.

## Calibration

`scripts/shader/ceilings.json` is the measured record, not a design target. Each ceiling is twice the highest valid normal-shader reading. Calibration on another GPU uses `scripts/measure-shader.sh --calibrate FILE`; it still requires the costly control to fail. The validator uses the committed record.

`scripts/measure-shader.sh` measured host cachy, NVIDIA GeForce RTX 5090, Vulkan, on 2026-09-30. Run `shader-cost-1790761862-2753669` supplied both scales. Run `shader-cost-1790761591-2346990` supplied another valid scale-1 reading; its scale-2 records were refused because the output still read scale 1. Only valid records contribute to the ceilings.

| Highest valid reading, ms | CPU sync | CPU render | GPU cost | Presentation |
|---|---|---|---|---|
| Scale 1 | 1 | 0 | 0.0036 | 41 |
| Scale 2 | 0 | 0 | 0.0042 | 72 |

The record holds the derived ceilings and costly-control readings. Qt truncates CPU readings to integer milliseconds. A zero render reading does not prove that rendering takes no CPU work. Its measured ceiling remains zero; any later positive integer reading fails.

## Layer presentation

`scripts/smoke/rows/shader-frames.sh` places the real `VoiceOrb` in the existing passive-layer fixture. The probe connects to that layer's `QQuickWindow`, not a bar. Frames must advance while listening. After transition frames settle, no frame may swap during a full two-second observation at `motion.scale` 0 or while the layer is unmapped.

The disconnected reader fails the advancing-frame assertion. A disposable orb without its zero-motion guard first proves it presents frames, then fails the quiet-window assertion. A remapped listening layer also fails that assertion. The row restores the theme, drops the copies and releases its window reader before it destroys the fixture. Unit properties and animation counts remain separate from this presentation evidence.

Omarchy's read-only `quattro` shell uses token-scaled Qt animations, such as `Ui/CursorSurface.qml`. It has no voice-orb or shader-cost instrument. VGS keeps Qt animation ownership and adds the measurements required by the [Jarvis plan §9](../plans/v2-jarvis-plan.md#9-testing-strategy).
