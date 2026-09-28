# Themes

Covers: themes/**, bin/vgsh-theme-judge, bin/lib/judge-files.js, scripts/test-vgsh-theme-judge.js, shell/Core/ThemeRunner.qml

A theme package is one directory. It holds the shell document and the application files that later apply steps copy or render. The package judge is pure; callers read files and pass their text to `ThemeLogic.acceptPackage`, and `bin/vgsh-theme-judge` owns the directory walk, the list and the apply.

## Package shape

| File | Required | Holds |
|---|---|---|
| `theme.json` | yes | The shell document from [design-system.md § The shell document](design-system.md#the-shell-document). |
| `terminal.json` | no | `{ "schemaVersion": 1, "slots": { "color0": "#...", ... "color15": "#..." } }`. |
| Application target files | no | Curated files a target later writes verbatim for its application. |

The directory name is the package name and must equal `theme.json`'s `name`; `ThemeLogic.isPackageName` bounds it to a letter or digit followed by letters, digits, `.`, `_` and `-`. The name `vgs` is reserved for the shipped defaults, so an installed package cannot hide the revert package. A package without `terminal.json` is valid; apply renders the shipped `vgs` terminal slots in its place.

## Boundaries

- `ThemeLogic.acceptPackage` takes the token table and file texts. It performs no I/O. It judges `theme.json` through `ThemeLogic.accept`, judges terminal slot names and colours, checks the directory/document name match, and applies the `vgs` reservation.
- `bin/vgsh-theme-judge` walks the package directories, reads `theme.json` and `terminal.json` and the theme file, and makes every decision through `ThemeLogic.js` and `Tokens.js`, loaded through `scripts/qml-library.js`. Its refusal and its file writes are `bin/lib/judge-files.js`, shared with `bin/vgsh-plugin-judge`.
- `shell/Core/ThemeRunner.qml` owns the apply process when the theme capability lands. It starts runner commands and reports their structured result; it does not judge package files itself.
- `shell/plugins/vgs.themes/**` belongs to [plugins.md](plugins.md). This topic covers package and core runner contracts only.

## Runner

`vgsh theme list [--json]` and `vgsh theme apply [--json] <name>` work with no shell running and never contact one. `bin/vgsh` parses the command line and takes the lock; `bin/vgsh-theme-judge` does the rest.

- **Packages.** Shipped packages are `themes/<name>/`, installed ones `${XDG_CONFIG_HOME:-~/.config}/vgs/themes/<name>/`; a symlink to a directory counts. An installed package hides the shipped package of its name, which is listed as `shadowed` and never read, even when the installed one is refused. An installed `vgs` is refused `reserved-name`, even when its files cannot be read, and hides nothing, so `apply vgs` always takes the shipped defaults.
- **List.** One row per package: its source (`shipped`, `installed`), its state (`ok`, `refused` with the judge's reason key, or `shadowed`), whether it is the theme file's named package and, when `ok`, its resolved `palette` group. The theme file's state is read from disk with `ThemeLogic.accept`, in `ThemeSource`'s vocabulary: `loaded`, `absent`, `refused`, `unreadable`. `modified` compares the file's bytes with the named package's `theme.json`: `false` for an absent file, `true` for a refused file or one no accepted package names, `null` for an unreadable one. `--json` prints `{ file: { path, state, name, modified }, packages: [{ name, source, path, state, reason, current, palette }] }` as one line.
- **Lock.** `apply` holds `flock` on `${XDG_CONFIG_HOME:-~/.config}/vgs/theme.lock`, beside the file it guards, so callers with different runtime directories serialise. The configuration directory is created first; the lock file is never removed. `bin/vgsh` holds it on a descriptor the judge inherits, so the lock lasts the whole apply. A second apply exits 75 with `reason=busy`; a lock that cannot be opened is `reason=lock-failed`.
- **State directory.** `${XDG_STATE_HOME:-~/.local/state}/vgs/`. Apply removes a `next-theme/` or `old-theme/` a crashed or refused apply left, writes the package's `theme.json` and `terminal.json`, or the shipped `vgs` slots, into `next-theme/`, then swaps it in. A rename cannot replace a non-empty directory, so `theme/` moves to `old-theme/`, `next-theme/` becomes `theme/` and `old-theme/` is removed. `theme/` is absent between the two renames; a failed second rename moves the old one back. Then `theme.name` holds the package name.
- **Theme file.** Last, the package's `theme.json` bytes replace `${XDG_CONFIG_HOME:-~/.config}/vgs/theme.json` by rename, so the shell restyles after the state directory holds the theme and never reads half a file. The copy is byte for byte: a re-serialised copy would report every apply as modified. A file already holding those bytes is not written.
- **Result.** `{ state, shell, targets, theme, reason }`. `shell` is `applied`, `unchanged` when the file already held the bytes, or `failed` when writing it failed. `state` follows `shell` (`applied`, `unchanged`, `failed`) until targets land; `targets` is `[]`. A refusal is `state: failed` with its `reason`: `malformed-name`, `busy`, `lock-failed`, `unknown`, `unwritable`, `unreadable`, `terminal-fallback` or the package's own. Text mode prints `ok theme=<name> state=<state> shell=<shell>`; `--json` prints the result as one line, refusals included, and each refusal also prints `vgsh: refused: theme=<name> reason=<key>` on stderr, a malformed name JSON-quoted. Exit 0, 1 on a refusal, 75 when busy, 2 on a bad invocation.

[D020](../decisions/D020-theme-apply-swaps-state-and-writes-the-shell-file-last.md) records the lock, the swap and the shadowing rule.

## Trust

Applying a third-party package carries plugin-level trust. A curated target file is written verbatim into a path an application includes, so package application has the same user-privilege impact as enabling a plugin. [D019](../decisions/D019-theme-packages-carry-plugin-trust.md) records the boundary.

## Invariants

1. The shipped `vgs` package is accepted, and an installed package named `vgs`, a directory name `isPackageName` refuses, a directory/document name mismatch, a bad terminal slot name and a bad terminal colour are refused. Enforced by `scripts/test-theme-logic.js`.
2. Every package under `themes/` passes the package judge in offline validation. Enforced by `bin/vgsh-theme-judge packages themes`, selected by `scripts/validate` for `themes/*` changes.
3. The nested smoke sandbox contains the shipped packages beside `shell`, `bin`, `config` and `scripts`. Owned by `scripts/smoke/harness.sh`.
4. An installed package shadows the shipped package of its name, and an installed `vgs` shadows nothing. Enforced by `scripts/test-vgsh.sh`.
5. The list reports a refused package with its reason, the theme file's state from disk and `modified` by a byte comparison; apply refuses a refused package. Enforced by `scripts/test-vgsh.sh`.
6. Apply copies `theme.json` byte for byte, renders `terminal.json` or the shipped slots, and leaves no `next-theme/`, a stale one included; `apply vgs` writes the shipped defaults. Enforced by `scripts/test-vgsh.sh`, with a re-serialising judge copy as its control.
7. A second apply is refused with `reason=busy` while the lock is held. Enforced by `scripts/test-vgsh.sh`, with a lockless `bin/vgsh` copy as its control.
