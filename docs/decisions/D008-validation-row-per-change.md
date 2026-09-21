# D008: Every change carries its validation row and runs only in the nested sandbox

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: The previous shell was validated per release and a second shell against the live session once blanked the desktop.

**Decision**: A change that adds a surface, a service or a plugin adds its row to `scripts/validate` in the same PR. `scripts/qml-smoke.sh` is the only place a shell starts from the repository, in a nested Hyprland with its own runtime dir, built from the repository alone. Every budget a script or document states was measured by that script on the machine and date it names.

**Rationale**:

- Per-change checks catch a regression in the change that made it.
- A sandbox whose verdict depends on the machine it ran on is not a sandbox.

**Revisit When**: CI gains a Wayland-capable runner, or a check needs host state the sandbox cannot reproduce.

**Verification**: `scripts/validate all`; the smoke's resident-size ceiling names its measurement.

**References**: `docs/architecture/runtime.md`
