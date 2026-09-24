# D007: Install runs no plugin code and lands the plugin disabled

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: A plugin repository can ship an install script. Running it at install would give any repository the user's privileges.

**Decision**: `vgsh plugin add` clones into staging, validates the manifest, refuses an id another plugin owns, moves the directory into place and leaves the plugin disabled. `update` fetches, shows the diff and fast-forwards only; it refuses a locally modified checkout and rolls back a version the manifest judge refuses. `remove` deletes only a directory `add` installed. None of them runs a script or a git hook from the plugin, and none asks for privilege. A plugin's external dependencies are declared, not installed by the plugin.

**Rationale**:

- It removes a supply-chain class for a one-line cost.
- Landing disabled gives the user a review step before any plugin code runs.

**Revisit When**: A plugin needs a system package the manager cannot declare, or the marketplace adds a signed install step.

**Verification**: The add, update and remove rows in `scripts/test-vgsh.sh`, which install from local bare repositories.

**References**: [D003](D003-everything-is-a-plugin.md)
