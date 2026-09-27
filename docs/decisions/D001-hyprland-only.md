# D001: Hyprland is the only compositor

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: The previous shell supported Hyprland and Niri. Every compositor-facing path existed twice and every review covered both.

**Decision**: v2 targets Hyprland alone. There is no compositor abstraction and no second compositor. `shell/Core/Compositor.qml` is the one dispatch path; `shell/Core/Dispatch.js` builds every request and speaks both Hyprland config dialects.

**Rationale**:

- One compositor halves the code paths that talk to the session and the review surface with them.
- The previous shell could not verify its Niri paths without Niri hardware.

**Revisit When**: A second compositor gains a Wayland protocol set the shell needs and a maintainer with the hardware to validate it.

**Verification**: `scripts/qml-smoke.sh` runs the shell under nested Hyprland only.

**References**: Niri support in the previous shell; `docs/architecture/overview.md`
