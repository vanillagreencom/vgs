# D006: Two configuration layers merged by entry id

[← Decision Index](INDEX.md)

**Date**: 2026-09-21

**Status**: Active

**Research**: —

**Context**: A shell that keeps one configuration file stops delivering shipped defaults the moment a user customises it. The previous shell had no shipped layer.

**Decision**: `config/shell.json` is the shipped layer and `~/.config/vgs/shell.json` the user layer. A user key replaces the shipped key whole, except `plugins`, merged by id with the user entry winning, and `disabledPlugins`, which is the user list. The manager seeds the user `bar` key from the effective bar before its first edit.

**Rationale**:

- A shipped default that never reaches a customised user file is a regression channel.
- Merge by id keeps the answer to "what is running" readable from two files, never a deep merge.

**Revisit When**: A third layer (system-wide under `/etc`) is needed, or a shipped default must override a user value.

**Verification**: `scripts/test-plugin-logic.js` pins each merge rule and the seeding.

**References**: [D005](D005-kinds-are-surfaces-no-dependencies.md)
