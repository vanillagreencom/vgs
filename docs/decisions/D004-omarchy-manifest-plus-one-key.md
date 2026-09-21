# D004: The plugin manifest is Omarchy Quattro's, whole, plus one reserved key

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: Omarchy 4 plugins are Quickshell QML components with a `manifest.json` (schema version 1). The owner wants every Omarchy plugin to load here and first-party plugins to publish there.

**Decision**: `manifest.json` follows the Omarchy Quattro schema exactly. v2 additions live under the one reserved key `vgs` (`capabilities`, `budgets`). `shell/Core/PluginLogic.js` is the one judge of a manifest.

**Rationale**:

- Two manifest formats need a translator, and a translator drifts.
- A plugin written for either shell validates in both without edits to its manifest.

**Revisit When**: Omarchy publishes schema version 2, renames a kind, or changes the injected properties or the `qs.Commons` and `qs.Ui` namespaces.

**Verification**: `scripts/check-manifests.js` validates every bundled manifest; the compatibility fixture row, once it exists, loads a marketplace plugin unchanged.

**References**: [D005](D005-kinds-are-surfaces-no-dependencies.md)
