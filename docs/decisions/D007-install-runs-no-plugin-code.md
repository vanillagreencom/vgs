# D007: Install runs no plugin code and lands the plugin disabled

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: Some marketplace plugins ship an `install.sh`. Running it at install would give any repository the user's privileges.

**Decision**: `vgsh plugin add` (not yet written) clones into staging, validates the manifest, refuses an id another plugin owns, moves the directory into place and leaves the plugin disabled. `update` fetches, shows the diff and fast-forwards only. Neither runs a script from the plugin nor asks for privilege. A plugin's external dependencies are declared, not installed by the plugin.

**Rationale**:

- Omarchy's installer rule; it removes a supply-chain class for a one-line cost.
- Landing disabled gives the user a review step before any plugin code runs.

**Revisit When**: A plugin needs a system package the manager cannot declare, or the marketplace adds a signed install step.

**Verification**: The manager's rows in `scripts/validate`, once install exists.

**References**: [D004](D004-omarchy-manifest-plus-one-key.md)
