# D004: The plugin manifest was another shell's schema plus one reserved key

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Superseded by [D011](D011-native-manifest-no-cross-shell-compatibility.md)

**Research**: —

**Context**: Another Hyprland shell on the same Quickshell runtime ships plugins as QML components with a `manifest.json`. The first design wanted every plugin from that shell to load here and first-party plugins to publish there.

**Decision**: `manifest.json` followed that shell's schema exactly, with v2 additions under one reserved key. `shell/Core/PluginLogic.js` was the one judge of a manifest.

**Rationale**:

- Two manifest formats need a translator, and a translator drifts.
- A plugin written for either shell would validate in both without edits to its manifest.

**Revisit When**: Superseded; see D011 for why the promise was withdrawn.

**Verification**: `scripts/check-manifests.js` validated every bundled manifest. The compatibility fixture row was never written.

**References**: [D005](D005-kinds-are-surfaces-no-dependencies.md), [D011](D011-native-manifest-no-cross-shell-compatibility.md)
