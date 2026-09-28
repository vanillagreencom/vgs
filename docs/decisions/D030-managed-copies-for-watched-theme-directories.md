# D030: Managed copies serve watched theme directories

[← Decision Index](INDEX.md)

**Date**: 2026-09-28
**Status**: Active
**Research**: VGS-492
**Refines**: [D022](D022-theme-apply-keeps-managed-links-in-application-directories.md), [D024](D024-theme-apply-sets-one-theme-key-in-an-application-settings-file.md)

**Context**: D022 keeps links in application theme directories. That works for applications that follow the link when they read the file. Claude Code, Hermes, Pi and oh-my-pi watch their own theme files or theme directories while a session runs. A `theme/` directory swap changes the linked target, not the watched directory entry, so those sessions can keep the old colours until restart.

**Decision**: The entry wiring form takes exactly one of `links` or `copies`. A copy entry writes the rendered target file into the application's theme directory by rename from a sibling staging file. A copy path is managed only when it is the old managed link to the same `theme/` file, or a regular file whose bytes equal either the previous render read from `theme/` before the swap or the new render. A user-edited file is occupied and is never replaced. A disabled target removes only a managed copy. D024 still owns the settings key, and apply keeps its byte-preserving edit instead of rewriting the whole settings file.

**Rationale**:

- A rename inside the application's watched directory gives directory and file watchers one complete changed file.
- The old managed link form is accepted so existing installs migrate on the next apply.
- Byte equality is the only marker a copy can carry without adding a second file; comparing both old and new bytes keeps unchanged applies quiet and lets a disabled target remove the copy it made.
- The single-key selection edit keeps credentials, comments and unrelated settings intact.

## Omarchy comparison

The design was compared with basecamp/omarchy's latest default branch, `quattro` at b18ab49. VGS takes Omarchy's core approach for the CLIs both systems serve: publish a stable named theme file into the CLI's own theme directory by atomic copy, set the stable theme key value and reload opencode with `SIGUSR2`.

VGS differs where Omarchy's desktop assumptions do not fit this repo:

- Omarchy rewrites settings files with `jq` and creates them when absent. VGS keeps [D024](D024-theme-apply-sets-one-theme-key-in-an-application-settings-file.md)'s byte-preserving single-key edit and never creates absent settings files, because these files can hold credentials and user formatting.
- Omarchy sets opencode to its `system` theme and sends `SIGUSR2` to every process named `opencode`. VGS renders its own opencode theme and signals only invocations positively known to mount the TUI theme handler: bare option-only commands, `attach` and project-directory arguments. `run`, `serve`, `web`, `acp` and ambiguous option values are skipped because they install no handler or cannot be classified safely, and the signal would end them.
- Omarchy publishes Hermes skins to every `profiles/*/skins` directory and activates the skin with `hermes config set`. VGS serves the default home only and sets the selection through its judged `select` edit, because apply does not run application CLIs and does not create profile homes.
- Omarchy overwrites its managed files unconditionally. VGS replaces a copy only while its bytes match the render VGS last landed or the new render, preserving [D022](D022-theme-apply-keeps-managed-links-in-application-directories.md)'s occupied-path rule for user-edited files.
- Omarchy has no Codex or Gemini counterpart. Codex keeps a link because it reads the theme at start and has no watch, and Gemini keeps no entry because its settings file names the state file directly.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Keep links and touch the link, as the old Claude hook did | A directory or file watcher still may not see the linked target's new bytes, and each watched CLI would need its own unproven nudge. |
| Omarchy's unconditional overwrite | It can replace a file the user edited or put there, while VGS's entry ownership rule says an occupied path is never replaced. |
| A marker or record file for copy ownership | The marker is a second artifact to keep in step with the copy, and losing it would either leak a managed file or overwrite a user's file. |
| Copies for every entry target | Codex and the editor targets read at start or follow links and have no running-session watcher to satisfy, so links keep their existing ownership proof and avoid needless writes. |

## Known limit

If an apply swaps `theme/` and then dies or fails before the wiring step updates a managed copy, the copy can hold bytes that match neither the previous `theme/` render nor the new one. The next apply treats it as `entry-occupied` so VGS does not overwrite possible user content. Recovery is manual: remove that stale copy, then apply the theme again.

**Revisit When**: A watched CLI cannot reload from an atomic copy, or a copied theme file needs permissions other than `0644`.

**Verification**: `scripts/test-theme-render.js` covers the `copies` schema and `entryItems` kind. `scripts/test-vgsh-entries.sh` covers create, unchanged, changed, old-link migration, occupied edited copies and disable removal. `scripts/test-vgsh-agents.sh` covers the agent CLI targets and opencode reload filtering.

**References**: [D021](D021-theme-apply-writes-beside-each-destination.md), [D022](D022-theme-apply-keeps-managed-links-in-application-directories.md), [D024](D024-theme-apply-sets-one-theme-key-in-an-application-settings-file.md)
