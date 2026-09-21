# D010: The plugin boundary is a static check plus a scoped API object, not a process sandbox

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: The owner's rule is that a plugin reads the core API and its own files only. Omarchy documents that a facade in one QML scene is an API boundary, not a sandbox, because a visual widget can walk the parent hierarchy to host objects. Quickshell's FAQ states that a process per widget costs significantly more memory.

**Decision**: A plugin file may import only the prefixes `scripts/check-plugin-boundary.py` allows (`QtQuick`, `QtQml`, `Qt.labs.`, `Quickshell`, `qs.Commons`, `qs.Ui`, never `Quickshell.Wayland` or `QtQuick.Window`) and files in its own directory, and may name no window type. At load a plugin receives a scoped `shell` object built from its manifest, never the host singletons. The shell process, scene and user privileges are shared. Sensitive state never relies on the scope alone.

**Rationale**:

- A process per plugin would multiply the resident size the runtime budgets bound, before any plugin exists to justify it.
- Static plus scoped catches the accidental coupling; the remaining risk is documented rather than pretended away.

**Revisit When**: The runtime budgets are measured against a process-per-plugin or engine-per-plugin design and it fits, or a plugin needs credentials the scope cannot protect.

**Verification**: `scripts/test-check-plugin-boundary.py` plants one violation per rule.

**References**: [D003](D003-everything-is-a-plugin.md)
