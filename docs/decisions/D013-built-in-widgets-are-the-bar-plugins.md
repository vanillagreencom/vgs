# D013: A built-in widget is part of the plugin that draws it, never a kind

[← Decision Index](INDEX.md)

**Date**: 2026-09-25

**Status**: Active

**Research**: —

**Context**: The shipped bar draws its own workspaces, clock and manager button inside its section containers, ahead of the plugin widgets the core mounts. The build records list everything on a surface, so those items had to appear there. The first implementation recorded them under a `kind` value of its own, which put a word outside `PluginLogic.KINDS` in the one field every host and script switches on.

**Decision**: A built-in widget is a category of the plugin that draws it. The plugin registers each one through its `builtins` capability as `shell.builtins.register(name, item)`. The core records it under the plugin's host key as `<plugin id>/<name>` with origin `plugin` and the registering instance's kind, so `kind` is only ever a member of `PluginLogic.KINDS`; an instance the core built carries origin `core`. The core builds none of it and the build counter does not move. The shipped bar chooses its built-ins from its own `left`, `center` and `right` settings.

**Rationale**:

- A bar owns the geometry of its sections; what it draws inside them is its own, and needs no manifest, no host and no enablement rule.
- One field with one closed value set keeps every switch on `kind` exhaustive; provenance is a second field, not a second kind.
- Registration keeps the build records complete, so the validation rows read every item on a surface from one place.

**Revisit When**: A second plugin needs to draw items inside another plugin's surface, or a built-in needs its own settings schema or enablement.

**Verification**: The `expect_builtins` rows in `scripts/qml-smoke.sh` read the registered built-ins back from the build records by origin.

**References**: [D003](D003-everything-is-a-plugin.md), [D005](D005-kinds-are-surfaces-no-dependencies.md), [D012](D012-core-owns-lent-objects.md)
