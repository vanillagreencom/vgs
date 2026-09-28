# D022: A theme apply keeps managed links in an application's own theme directory

[← Decision Index](INDEX.md)

**Date**: 2026-09-27

**Status**: Revisited

**Research**: VGS-468

**Refines**: [D021](D021-theme-apply-writes-beside-each-destination.md)

**Context**: D021 lets an apply write one include line in an application's configuration file and nothing else in the application's directory. Helix, Zed and VS Code read no include line. Helix and Zed find a theme by name in a themes directory of their own, and VS Code finds one in an extension directory under `~/.vscode/extensions/`. A target for any of them needs a file in that directory.

**Decision**: A target's `wiring` takes a second form, `{ base, dir, owned, links }`. It keeps one symlink per link in `dir`, under the `base` it names: `config`, the configuration home; `home`, the home directory; or `cache`, the cache home, `${XDG_CACHE_HOME:-~/.cache}`. The symlink names the target's file in the state directory's `theme/`. The apply never edits the application's configuration, and the user selects the theme once in the application. The proof that a link is managed is the link itself: a symlink whose target is exactly its file in `theme/`. A path holding anything else skips the target with `entry-occupied` and is never replaced. A disabled target removes only its managed links, then its `owned` directory once it is empty. D021's other rules stand: every file the application reads is still written by the stage and swap into `theme/`, and the include form is unchanged.

**Rationale**:

- A symlink into `theme/` keeps D021's stable path. The swap replaces `theme/` whole, so the link names the new file after every apply and never has to be written again.
- Nothing but an apply makes a symlink into the state directory's `theme/`, so no marker file or record of what the apply created is needed. A dangling managed link is still recognised, and a user's file, directory or link to elsewhere never is.
- An owned directory, such as an extension directory, is removed only by `rmdir`, so a file the user put inside it keeps the directory.
- Resolving `dir` where it stands serves a dotfile manager's symlinked directory, as D021's resolved include file does.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Copy the rendered file into the application's directory | Every apply writes there again, and a copy the user edited cannot be told apart from the apply's own. |
| A marker file beside each entry | The marker is a second file to keep in step with the first, and it must itself be told apart from the user's. |
| Edit the application's settings to select the theme | Zed's and VS Code's settings are JSON with comments, which no line edit keeps whole, and selecting the theme is the user's choice. |

**Revisit When**: An application refuses to follow a symlink in its theme or extension directory, or a target needs a file the application reads that is not one of its files in `theme/`.

**Verification**: `scripts/test-theme-render.js` covers the form's schema with a control per rule. `scripts/test-vgsh-entries.sh` covers the links, the symlinked directory, the occupied paths and the removal. Its controls are judge copies that take any symlink as managed, skip the occupancy check, never remove or recursively remove the owned directory, remove any path at a link's name, misplace a `home` directory and ignore `XDG_CACHE_HOME` for a `cache` one.

## Revisit Outcome (2026-09-27)

The decision stands. VGS-470 adds the entry base `cache`, `${XDG_CACHE_HOME:-~/.cache}`, resolved by the apply from `XDG_CACHE_HOME` as `home` is from the home directory. Its first user is the `pywalfox` target, whose native host reads pywal's `colors.json` from `wal/` there: [theme-browsers.md](../architecture/theme-browsers.md).

## Revisit Outcome (2026-09-28)

The decision stands for links. VGS-471 adds [D024](D024-theme-apply-sets-one-theme-key-in-an-application-settings-file.md): a target with a `select` key also sets one theme key in its application's own settings file, so the user no longer selects that theme by hand. Every other target still edits no application configuration.

## Revisit Outcome (2026-09-28, VGS-492)

The decision stands for applications that follow symlinks at read time. [D030](D030-managed-copies-for-watched-theme-directories.md) adds managed copies for applications whose running sessions watch their own theme directory or active theme file. The entry wiring form now carries exactly one of `links` or `copies`.

**References**: [D021](D021-theme-apply-writes-beside-each-destination.md), [D019](D019-theme-packages-carry-plugin-trust.md)
