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

Each stream discards 120 warmup readings and keeps 600 samples. Each reading is the nearest-rank 90th percentile of its 600 samples, `PERCENTILE` in `scripts/shader/readings.py`; for GPU cost it is the percentile of the 600 paired deltas. A busy host delays a few frames, and the highest sample follows those frames, not the shader: 9 kept runs of other worktrees on host cachy on 2026-09-30, read through `readings.py`'s `scene` and `percentile`, gave 14 scale readings whose highest GPU delta was 0.0033 to 0.0158 ms and whose 90th percentile was 0.0012 to 0.0024 ms. Missing, empty or incomplete streams fail. The reader refuses a wrong window, scale or swap interval. A software device exits 77. Check mode also requires every scene at every scale to match the baseline's backend and device; a mismatch exits 77 as uncalibrated. The Vulkan backend supplies device identity and GPU timestamps; absent GPU timestamps fail rather than substituting presentation intervals.

The instrument compiles a disposable shader with a 256-step dependent loop. It uses `qsb_tool()` and `OPTIONS` from the shipped pack's compiler owner, `scripts/check-voiceorb-shader.py`. The costly shader must exceed the GPU ceiling at both scales. A CPU scheduling delay or a slow presentation alone does not satisfy that control. `scripts/test-measure-shader.py` exercises calibration and committed-baseline check mode through the reader and its CLI. It covers normal regressions, an accepted costly control, calibration identity within a pass and across passes, a single spike in each stream, an unresolved GPU cost at the 90th percentile, calibration over several passes and check mode's one directory. Disposable mutations remove the sample guard, ceiling guard, baseline rejection, identity checks, the percentile of each stream, the unresolved-cost guard, pass loop, per-pass control and directory refusal and turn their tests red.

The runner creates its scratch directory before it exports `TMPDIR` or starts the harness. Each scene runs under the output's held mode through `measure_held_scene` in `scripts/shader/measure-scene.sh`. The host's configure of the nested window can move the output off that mode during a scene ([runtime-hyprland-nested.md](runtime-hyprland-nested.md)). At scale 2 only the hold's rule puts the mode back, so a scene after which the output still reads the held mode ran under it throughout. At scale 1 a host resize away and back restores the hold without its rule, and the reading after the scene cannot see it; the scale stays 1 and the layer's size is fixed, so only the frames around the two changes are affected, and the 90th-percentile reading absorbs a few such frames. A scene after which the output reads a reset is discarded: the runner prints `shader-cost: mode-reset scene=<scene> scale=<n> got=[<reading>] attempt=<k>`, takes the hold again through `hold_restore` and measures the scene again, up to `scene_attempts` times. Past that bound the reset uses the shared `smoke_verdict` and exits 77 when it is the only failure. A hold that cannot be taken again, unreadable output state and earlier real failures remain failures. Each scene line records `cpu_some_pct`, the percent of the scene's window in which some runnable task on the host waited for a CPU; it is a record, not a gate. The isolated runner tests exercise these paths without rendering. They also remove scratch creation, compiler-option forwarding, the held-scene call, the pass loop, the passes handed to the reader, the second measurement, the reset count, the restore check, the unreadable-output failure and the `--runs` refusal in disposable copies.

## Calibration

`scripts/shader/ceilings.json` is the measured record, not a design target. Calibration uses `scripts/measure-shader.sh --calibrate FILE --runs N`, which measures N passes in one sandbox, each in its own logs directory. Each ceiling is twice the highest reading over every pass and scale. The costly control of every pass must exceed the GPU ceiling at both scales. The record lists each pass under `calibration_runs`. Check mode measures one pass; `--runs` without `--calibrate` is refused. The validator uses the committed record.

`scripts/measure-shader.sh --calibrate scripts/shader/ceilings.json --runs 3` measured host cachy, NVIDIA GeForce RTX 5090, Vulkan, on 2026-09-30, run `shader-cost-1790788228-2717803`. The 1-minute load average read 11.75 at its start and 8.72 at its end on 32 CPUs, and every scene line read `cpu_some_pct` from 0.4 to 1.3. One scene, pass 2 costly at scale 2, read a mode reset once and measured again.

| Highest reading over 3 passes, ms | CPU sync | CPU render | GPU cost | Presentation |
|---|---|---|---|---|
| Scale 1 | 0 | 0 | 0.0022 | 34 |
| Scale 2 | 0 | 0 | 0.0021 | 34 |

The costly control read a GPU cost of 0.0144 to 0.0148 ms at scale 1 and 0.0197 to 0.0204 ms at scale 2. Qt truncates CPU readings to integer milliseconds. A zero reading does not prove that sync or render takes no CPU work. Their measured ceilings remain zero; a later 90th percentile of 1 ms or more fails.

## Layer presentation

`scripts/smoke/rows/shader-frames.sh` places the real `VoiceOrb` in the existing passive-layer fixture. The probe connects to that layer's `QQuickWindow`, not a bar. Frames must advance while listening. After transition frames settle, no frame may swap during a full two-second observation at `motion.scale` 0 or while the layer is unmapped.

The disconnected reader fails the advancing-frame assertion. A disposable orb without its zero-motion guard first proves it presents frames, then fails the quiet-window assertion. A remapped listening layer also fails that assertion. The row restores the theme, drops the copies and releases its window reader before it destroys the fixture. Unit properties and animation counts remain separate from this presentation evidence.

Omarchy's read-only `quattro` shell uses token-scaled Qt animations, such as `Ui/CursorSurface.qml`. It has no voice-orb or shader-cost instrument. VGS keeps Qt animation ownership and adds the measurements required by the [Jarvis plan §9](../plans/v2-jarvis-plan.md#9-testing-strategy).
