# D024: A theme apply sets one theme key in an application's own settings file

[← Decision Index](INDEX.md)

**Date**: 2026-09-28

**Status**: Active

**Research**: VGS-471

**Refines**: [D022](D022-theme-apply-keeps-managed-links-in-application-directories.md)

**Context**: D022 keeps a target's files in an application's theme directory and leaves the selection to the user, because Zed's and VS Code's settings are JSON with comments that no line edit keeps whole. The coding-agent CLIs, Claude Code, Codex, Gemini CLI, Hermes Agent, opencode and Pi, find a theme by name the same way but take the name from a key in their own settings file, plain JSON, TOML or YAML. Without that key the theme file is never read, and a CLI's own theme picker or a hand edit moves the key away from it.

**Decision**: A target may carry `select`, `{ base, file, format, key, value }`, beside any wiring form. Apply sets that one key to that value in that file on every apply that lands the target, unchanged bytes included, and changes no other byte of the file. `bin/lib/theme-select.js` makes the edit in memory: a JSON file must parse whole, and a TOML or YAML file is edited line by line under its table or mapping, never re-serialised. A file whose key cannot be set without guessing where it lives is refused, and so is a JSON file with comments. An absent settings file is never created. A refused or absent file skips the target before anything lands. The file is resolved through symlinks and replaced by rename beside the resolved file with its mode kept, as D021 edits an include line's file; the staging copy is created owner-only and takes the kept mode once it is full. A disabled target leaves the key as it stands. D022's other rules stand: the links, their ownership proof and their removal are unchanged.

**Rationale**:

- The key is the one setting that makes the CLI read the linked file, so a theme apply that leaves it to the user leaves the CLI on another theme after every `/theme` pick or hand edit. Setting it on every apply puts it back.
- Setting a key edits the user's file, so the edit is as narrow as the file allows: one key, one token or one added line. A refusal on any shape the edit cannot read keeps a file the edit would otherwise damage, and leaves the CLI on its last theme.
- These files hold credentials and provider settings, so an absent file is never created: the CLI's defaults stand until the user makes one, and a dotfile manager's link to a shared file stays a link.
- Apply does not know which theme the user had before, so a disabled target leaves the key rather than guessing. The CLI falls back to its default once the theme file is gone.
- The edit runs in the judge at the wiring step, not as a reload hook: a hook's command is looked up on `PATH`, where no helper of the repository is, and the wiring step already runs on every landing apply.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Leave the selection to the user, as D022 does for editors | A `/theme` pick or a hand edit moves the key away, and the CLI never reads the theme again. |
| Parse and re-serialise the settings file | TOML and YAML comments, key order and quoting would be lost; the repository ships no TOML or YAML library. |
| A reload hook that runs a selection helper | The hook's command is found on `PATH`, and the shipped helpers are not on it. |
| Create an absent settings file holding the key | The file would carry an owner's mode and content the CLI never chose, beside a user who never ran the CLI. |
| Restore the previous theme on disable | Apply never recorded it, and a record of the user's settings is a second state to keep in step. |

**Revisit When**: A CLI names its theme in a file this edit refuses in its common form, such as JSON with comments, or takes its theme from a place other than a settings key.

**Verification**: `scripts/test-theme-select.js` covers every edit and refusal for each format and the `select` schema, with a control per rule on copies of `theme-select.js` and `theme-render.js`. `scripts/test-vgsh-agents.sh` covers the six targets, the byte-for-byte edit through a symlink with its mode, the skipped absent and refused files, the restored key and the disabled target. Its controls are judge copies that drop the plan's skip and never keep the selection.

**References**: [D022](D022-theme-apply-keeps-managed-links-in-application-directories.md), [D021](D021-theme-apply-writes-beside-each-destination.md)
