# D005: Kinds are surfaces and plugins declare no dependencies

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: A first design let a plugin require another by id and had the manager refuse to disable a required plugin. The owner rejected that as a flat structure was simpler and a plugin should keep working when part of it has nowhere to draw.

**Decision**: A plugin declares the kinds it can fill: `bar-widget`, `bar`, `panel`, `overlay`, `menu`, `service`. The core owns the list; a new kind is a core change with its own host. A kind whose host is absent is not shown and the plugin's other kinds keep working. A manifest `requires` key is refused. Disabling the active bar answers with the widgets it hides; they stay enabled.

**Rationale**:

- A closed kind list lets the core own placement, lifecycle and per-kind scoping.
- No dependency graph means no load order to derive, no refusal to explain, and no plugin that names another.

**Revisit When**: A plugin genuinely cannot work without another plugin's service and no core capability can carry that contract.

**Verification**: `scripts/test-plugin-logic.js` pins the `requires` refusal and `hiddenByDisabling`; `scripts/qml-smoke.sh` asserts the hidden-widgets reply.

**References**: [D003](D003-everything-is-a-plugin.md), [D011](D011-native-manifest-no-cross-shell-compatibility.md)
