# D002: Quickshell 0.3.1 is the baseline

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: Quickshell moves fast and its module imports, path helpers and CLI flags changed between 0.2 and 0.3.

**Decision**: The shell requires Quickshell 0.3.1 or newer. Every QML type, property and signal the shell uses is taken from the 0.3.1 reference, cited, never from memory.

**Rationale**:

- The reference machine runs 0.3.1 and every measurement in `docs/architecture` was taken on it.
- A cited reference keeps agents from using a property that a newer or older release lacks.

**Revisit When**: A Quickshell release changes the `qs.` import resolution, the `qs ipc` CLI, `FileView`, `Process` or the window types the hosts use.

**Verification**: `docs/architecture/runtime.md` names the measured facts and the version they hold on.

**References**: [D001](D001-hyprland-only.md)
