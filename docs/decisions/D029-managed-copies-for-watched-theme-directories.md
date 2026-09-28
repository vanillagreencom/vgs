# D029: Managed copies serve watched theme directories

[← Decision Index](INDEX.md)

**Date**: 2026-09-28
**Status**: Active
**Research**: VGS-492
**Refines**: [D022](D022-theme-apply-keeps-managed-links-in-application-directories.md), [D024](D024-theme-apply-sets-one-theme-key-in-an-application-settings-file.md)

**Context**: D022 keeps links in application theme directories. That works for applications that follow the link when they read the file. Claude Code, Pi and oh-my-pi watch their own theme files or theme directories while a session runs. A `theme/` directory swap changes the linked target, not the watched directory entry, so those sessions can keep the old colours until restart.

**Decision**: The entry wiring form takes exactly one of `links` or `copies`. A copy entry writes the rendered target file into the application's theme directory by rename from a sibling staging file. A copy path is managed only when it is the old managed link to the same `theme/` file, or a regular file whose bytes equal either the previous render read from `theme/` before the swap or the new render. A user-edited file is occupied and is never replaced. A disabled target removes only a managed copy. D024 still owns the settings key, and apply keeps its byte-preserving edit instead of rewriting the whole settings file.

**Rationale**:

- A rename inside the application's watched directory gives directory and file watchers one complete changed file.
- The old managed link form is accepted so existing installs migrate on the next apply.
- Byte equality is the only marker a copy can carry without adding a second file; comparing both old and new bytes keeps unchanged applies quiet and lets a disabled target remove the copy it made.
- The single-key selection edit keeps credentials, comments and unrelated settings intact.

**Revisit When**: A watched CLI cannot reload from an atomic copy, or a copied theme file needs permissions other than `0644`.

**Verification**: `scripts/test-theme-render.js` covers the `copies` schema and `entryItems` kind. `scripts/test-vgsh-entries.sh` covers create, unchanged, changed, old-link migration, occupied edited copies and disable removal. `scripts/test-vgsh-agents.sh` covers the agent CLI targets and opencode reload filtering.

**References**: [D021](D021-theme-apply-writes-beside-each-destination.md), [D022](D022-theme-apply-keeps-managed-links-in-application-directories.md), [D024](D024-theme-apply-sets-one-theme-key-in-an-application-settings-file.md)
