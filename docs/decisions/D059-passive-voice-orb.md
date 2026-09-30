# D059: VoiceOrb is a generic passive visual in qs.Ui

[← Decision Index](INDEX.md)

**Date**: 2026-09-30
**Status**: Active
**Research**: [Jarvis plan §10](../plans/v2-jarvis-plan.md#10-decisions-to-record)
**Refines**: [D015](D015-tokens-are-a-judged-table.md), [D026](D026-passive-layers-are-a-capability.md)

**Context**: A listening indicator needs a reusable visual before a voice plugin or its bubble exists. The indicator must remain useful under reduced motion and must not take a press from the application below a passive layer.

**Decision**: `VoiceOrb` in `qs.Ui` is decorative. Its inputs are tone, primary level, secondary level and active state. One baked fragment shader draws a thin ring and fine concentric arcs from `voiceOrb` tokens. Its frame driver runs only in a visible, non-minimized host while the component is visible, active and motion is enabled. It has no pointer handler, mute action, accessible control or microphone dependency. A plugin places labelled actions outside it.

**Rationale**:
- A generic component keeps voice state and audio ownership out of the core. The caller maps its state to palette-derived tones.
- A click to mute on the decoration is not discoverable and could take input from another application. A mute key or labelled control remains available when the visual is absent.
- The owner's shader references supply the uniform model and attack/release smoothing approach. Their fixed palettes, noise layers and volumetric march do not fit a token-driven line visual.
- The read-only Omarchy quattro reference has a component Gallery and audio controls, but no voice-orb counterpart. VGS keeps its composition approach and adds this component for the plan's passive indicator.
- A QML shape stack or a Canvas is an alternative, but the plan selects one analytic shader. It needs no texture, blur or iteration. GPU measurement and presentation checks belong to J08; this record claims no cost budget.

**Revisit When**: A consumer needs an interactive visual, or J08's GPU readings require a different rendering mechanism.

**Verification**: `scripts/qml-tests/tst_voiceorb.qml` reads properties and animation lifetime, with mutations in `scripts/test-qml-unit.sh`. `scripts/check-voiceorb-shader.py` compiles and checks the shipped pack, with controls in `scripts/test-check-voiceorb-shader.py`. `scripts/smoke/rows/gallery.sh` reads the examples and compiled shader status, beside an uncompiled control. The read-only prefix row runs the installed component.

**References**: [Jarvis plan §4.3](../plans/v2-jarvis-plan.md#43-bubble-and-orb), [runtime-qml-shaders.md](../architecture/runtime-qml-shaders.md)
