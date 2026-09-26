# D009: One manifest judge shared by the shell and the scripts, run under node

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: Manifest validation, configuration merging and enablement are needed by the shell at runtime and by the checks offline. Two implementations would drift.

**Decision**: `shell/Core/PluginLogic.js` is a pure `.pragma library` file with no QML object and no I/O. The shell imports it; `scripts/test-plugin-logic.js`, `scripts/check-manifests.js` and `vgsh plugin validate` run it under node. Node is a validation-time dependency.

**Rationale**:

- One judge per question; a second copy is a twin even when both agree.
- Pure functions test under node in milliseconds without a compositor.

**Revisit When**: A decision needs QML types (a `ShellScreen`, a `Process`) that node cannot host, or node becomes unavailable on the reference machine.

**Verification**: `scripts/test-plugin-logic.js` and `scripts/check-manifests.js` both load the same file.

**References**: [D011](D011-native-manifest-no-cross-shell-compatibility.md)
