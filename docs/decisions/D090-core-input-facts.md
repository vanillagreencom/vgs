# D090: Core owners supply read-only input facts

[← Decision Index](INDEX.md)

**Date**: 2026-10-02
**Status**: Active
**Research**: [Jarvis plan](../plans/v2-jarvis-plan.md#37-policy-authority-effects-approval-audit)
**Refines**: [D059](D059-keycodes-and-effective-shortcut-keys.md), [D070](D070-jarvis-action-policy.md)

**Context**: Synthetic input must not activate the assistant's controls or deliver input to a protected surface. Effective key strings do not resolve physical key aliases. An active application can remain listed while a shell layer owns the keyboard.

**Decision**: Existing Hyprland device and compositor owners provide fresh key and target observations. The core key judge normalizes strings. A read-only system XKB helper resolves both the active device layout and Hyprland's global group-zero bind translation map. Core hosts register raw Qt window activation with the compositor owner. The router reserves its serial slot while observations await their reply. Protected rectangles include pass-through gaps.

**Rationale**:
- A plugin-owned key or target reader would duplicate the core's device and surface facts.
- Resolving symbol and code aliases through the system library avoids a second layout inventory.
- The compositor exposes rectangular layers but no public input mask. Refusal of their gaps can lose usable clicks. Guessing permission could click an approval control.
- Omarchy's voice tools use wtype and an input daemon. VGS keeps the typed input transport but retains its own serial policy and protected-target rules.

**Alternatives considered**:
- Literal key comparison misses symbol and keycode aliases.
- A plugin-owned physical device reader needs permissions and bypasses the existing device owner.
- Treating an empty part of a protected rectangle as safe depends on an input region the compositor does not expose.

**Boundaries**: Facts grant no input authority. Policy owns grants and terminal restrictions. Input owns transport children. No setup changes a unit, module, group or global input option. Another same-user program can still generate physical-looking input outside Jarvis.

**Revisit When**: Hyprland exposes atomic target-bound input or public protected input regions.

**Verification**: `scripts/test-input-facts.js`, `scripts/test-xkb-keys.py`, `scripts/test-jarvis-input.js` and the nested `input-facts` row, with independent must-fail controls.

**References**: [Core input facts](../architecture/input-facts.md), [Jarvis input](../architecture/jarvis-input.md)
