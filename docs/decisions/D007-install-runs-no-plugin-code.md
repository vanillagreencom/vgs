# D007: Install runs no plugin code and lands the plugin disabled

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active (system-package declaration → D035)

**Research**: —

**Context**: A plugin repository can ship an install script. Running it at install would give any repository the user's privileges.

**Decision**: `vgsh plugin add` clones into staging, validates the manifest, refuses an id another plugin owns, moves the directory into place and leaves the plugin disabled. `update` fetches, shows the diff, asks for confirmation and fast-forwards only; it refuses a locally modified checkout, refuses without a terminal unless `--yes` gives the answer, and rolls back a version the manifest judge refuses. `vgsh theme update` asks the same question through the same code. `remove` deletes only a directory `add` installed. None of them runs a script or a git hook from the plugin, and none asks for privilege. The manager installs nothing for a plugin: a system package a plugin needs is the user's to install, and the manifest has no key for it.

**Rationale**:

- It removes a supply-chain class for a one-line cost.
- Landing disabled gives the user a review step before any plugin code runs. An update replaces code that may already be enabled, and a running shell rescans at once, so its review step is the question after the diff.

**Revisit When**: A plugin needs a system package the manager cannot declare, or the marketplace adds a signed install step.

**Verification**: The add, update and remove rows in `scripts/test-vgsh.sh`, which install from local bare repositories.

**References**: [D003](D003-everything-is-a-plugin.md)

## Revisit Outcome (2026-09-28)

The first revisit condition is met: plugins need system packages, and [D035](D035-manifest-requirements.md) lets a manifest declare them as `requirements`, which replaces "the manifest has no key for it". The rest holds. Install still runs no plugin code, lands the plugin disabled and asks for no privilege; the manager reads `requirements` as data and reports each command's state. Installing a missing package is a core TUI the user starts, where the package manager asks for root in the user's terminal ([D034](D034-one-package-manager-table.md)).
