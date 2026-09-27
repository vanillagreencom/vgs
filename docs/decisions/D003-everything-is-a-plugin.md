# D003: Everything outside the core is a plugin and the plugin manager is core

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: The previous shell mixed features into its core, so a change to one surface could break another and no agent could hold the core in context.

**Decision**: Every visible surface and every service is a plugin under `shell/plugins/` or the user plugin directory. The core is `shell/` outside `shell/plugins/`, `bin/` and `config/`: process, lock, compositor link, theme tokens, hosts, registry, manager and IPC. The core names no plugin; `config/shell.json` names the default bar. The manager mechanism is core because it must exist before any plugin and keep working when one breaks; its user interface is a plugin.

**Rationale**:

- A small privileged core fits in one agent's context and changes rarely.
- A plugin change cannot reach another plugin, so review scope is the plugin.

**Revisit When**: A feature needs a surface no host can give and the host cannot be added without a core rewrite, or the core grows past what one agent holds.

**Verification**: `scripts/check-plugin-boundary.py` refuses a plugin id literal or a plugin import in the core.

**References**: [D005](D005-kinds-are-surfaces-no-dependencies.md), [D010](D010-facade-scope-not-sandbox.md)
