# Themes

Covers: themes/**, bin/vgsh-theme-judge, bin/lib/judge-files.js, scripts/test-vgsh-theme-judge.js

A theme package is one directory. It holds the shell document and the application files that later apply steps copy or render. The package judge is pure; callers read files and pass their text to `ThemeLogic.acceptPackage`, and `bin/vgsh-theme-judge` owns the directory walk, the list and the apply.

## Package shape

| File | Required | Holds |
|---|---|---|
| `theme.json` | yes | The shell document from [design-system.md § The shell document](design-system.md#the-shell-document). |
| `terminal.json` | no | `{ "schemaVersion": 1, "slots": { "color0": "#...", ... "color15": "#..." } }`. |
| `targets/<target>.<ext>` | no | A curated file, taken verbatim in place of the target file the renderer writes to that name: [theme-targets.md § Templates](theme-targets.md#templates). |

The directory name is the package name and must equal `theme.json`'s `name`; `ThemeLogic.isPackageName` bounds it to a letter or digit followed by letters, digits, `.`, `_` and `-`. The name `vgs` is reserved for the shipped defaults, so an installed package cannot hide the revert package. A package without `terminal.json` is valid; apply renders the shipped `vgs` terminal slots in its place.

The shipped packages are `vgs`, the dark defaults and the revert, and `light`, the shipped light package. The format holds no light or dark field, so a surface that offers a light mode picks `light` by name. `light` sets the seven palette colours and `color.textFaint`, with its own `terminal.json`. The default faint mix, 0.42 of the way to the background, gives faint text a WCAG contrast of 3.89:1 on the light `color.surface`. At 0.36 the ratio is 4.76:1, beside the 4.79:1 `vgs` draws. Each ratio is `ThemeLogic.luminance` over the resolved tokens, computed under node on 2026-09-27.

## Boundaries

- `ThemeLogic.acceptPackage` takes the token table and file texts. It performs no I/O. It judges `theme.json` through `ThemeLogic.accept`, judges terminal slot names and colours, checks the directory/document name match, and applies the `vgs` reservation.
- `bin/vgsh-theme-judge` walks the package and target directories, reads every file an apply needs, and makes every decision through `ThemeLogic.js`, `Tokens.js` and, for `shell.json`, `PluginLogic.js`, loaded through `scripts/qml-library.js`. Its refusal and its file writes are `bin/lib/judge-files.js`, shared with `bin/vgsh-plugin-judge`.
- `bin/lib/theme-render.js` judges `target.json`, renders templates and chooses the terminal slots. It performs no I/O: the judge reads every file and passes its text or bytes, with `ThemeLogic.js` and the token table as arguments, so a token path means what it means to the shell.
- `shell/Core/ThemeRunner.qml` owns the `vgsh theme` process behind the `theme` capability: [theme-capability.md](theme-capability.md). It starts runner commands and reports their structured result; it judges no package file itself.
- `shell/plugins/vgs.themes/**` belongs to [plugins.md](plugins.md). This topic covers package and core runner contracts only.

## Runner

`vgsh theme list [--json]` and `vgsh theme apply [--json] <name>` work with no shell running and never contact one. `bin/vgsh` parses the command line and takes the lock; `bin/vgsh-theme-judge` does the rest.

- **Packages.** Shipped packages are `themes/<name>/`, installed ones `${XDG_CONFIG_HOME:-~/.config}/vgs/themes/<name>/`; a symlink to a directory counts. An installed package hides the shipped package of its name, which is listed as `shadowed` and never read, even when the installed one is refused. An installed `vgs` is refused `reserved-name`, even when its files cannot be read, and hides nothing, so `apply vgs` always takes the shipped defaults.
- **List.** One row per package: its source (`shipped`, `installed`), its state (`ok`, `refused` with the judge's reason key, or `shadowed`), whether it is the theme file's named package and, when `ok`, its resolved `palette` group. The theme file's state is read from disk with `ThemeLogic.accept`, in `ThemeSource`'s vocabulary: `loaded`, `absent`, `refused`, `unreadable`. `modified` compares the file's bytes with the named package's `theme.json`: `false` for an absent file, `true` for a refused file or one no accepted package names, `null` for an unreadable one. `--json` prints `{ file: { path, state, name, modified }, packages: [{ name, source, path, state, reason, current, palette }] }` as one line.
- **Lock.** `apply` holds `flock` on `${XDG_CONFIG_HOME:-~/.config}/vgs/theme.lock`, beside the file it guards, so callers with different runtime directories serialise. The configuration directory is created first; the lock file is never removed. `bin/vgsh` holds it on a descriptor the judge inherits, so the lock lasts the whole apply. A second apply exits 75 with `reason=busy`; a lock that cannot be opened is `reason=lock-failed`.

[D020](../decisions/D020-theme-apply-swaps-state-and-writes-the-shell-file-last.md) records the lock, the swap and the shadowing rule.

## Install

`vgsh theme add <git url>`, `vgsh theme update <name>` and `vgsh theme remove <name>` install, fast-forward and delete packages under `${XDG_CONFIG_HOME:-~/.config}/vgs/themes/`. They share the git handling of `vgsh plugin add`, `update` and `remove` ([manager.md](manager.md)): no git hook, no submodule and no package file runs, and no privilege is asked for. They never contact the shell. `bin/vgsh-theme-judge accept` judges a package through `ThemeLogic.acceptPackage`, and `bin/vgsh-theme-judge installed` resolves the directory update and remove act on.

- **Add.** The clone lands in a staging directory beside `themes/`, so no list reads half a package. The package's name is its `theme.json` document name, read by `ThemeLogic.accept`. The judge then accepts the package under that name as an installed one, so the reserved `vgs`, a name `isPackageName` refuses and a bad terminal file are refused. `targets` is refused `reserved-name`, since a themes directory's `targets/` is never read as a package. A source without `theme.json` is refused `absent`. An occupied `themes/<name>` is refused `exists`. An add may shadow a shipped package of its name, as [§ Runner](#runner) lists it, and its line then names the shipped path: `ok added=<name> path=<dir>[ shadows=<shipped dir>]`.
- **Update.** Update refuses a checkout with local changes or untracked files, prints the incoming diff and fast-forwards only. A version the judge refuses under the installed name, a renamed document included, is rolled back before the refusal. The package the theme file names keeps its applied bytes until the next `theme apply`, so `theme list` reports the file `modified`.
- **Remove.** Remove deletes `themes/<name>`, an installed `vgs` included, and never a shipped package, a symlink or a file.
- **Resolution.** Update and remove refuse a name `isPackageName` refuses as `malformed-name`, `targets` as `reserved-name`, a name only a shipped package has as `shipped`, and any other absent name as `unknown`.
- **Lock.** Each verb holds the `theme.lock` apply holds, from before it changes `themes/` until it exits, so no apply reads a package mid-change. Add takes it after the clone and the judge. No git call inherits its descriptor, so a gc git detaches never holds it. A held lock exits 75 with `vgsh: refused: theme=<name> reason=busy`, and an apply started meanwhile is refused `reason=busy`.
- **Refusals.** A judge refusal prints `vgsh: refused: package=<url> reason=<key> ...` on add and `vgsh: refused: theme=<name> reason=<key> ... rolled-back=<commit>` on update. Every other refusal names `theme=<name> reason=<key>`, or the git key the plugin verbs use. Exit 0, 1 on a refusal, 75 when busy, 2 on a bad invocation; the verbs take no `--json`.

## Apply

`vgsh theme apply <name>` lands the package in the state directory, `${XDG_STATE_HOME:-~/.local/state}/vgs/`, and in every enabled target, then in the shell. Targets are the shipped `themes/targets/<target>/`: [theme-targets.md](theme-targets.md). The steps run in this order under the lock.

1. **Enablement.** A target is enabled when every `detect` command is on `PATH` and the effective `shell.json`'s `disabledTargets` does not list it: [configuration.md § shell.json keys](configuration.md#shelljson-keys). Either layer that `PluginLogic.configError` refuses refuses the apply with `reason=malformed`, since no target's enablement is then known. A target whose `wiring.create` is `false` and whose wiring file is absent is skipped. A skipped target renders nothing and lands no file.
2. **Render.** Every enabled target renders in memory, with the package's curated files and terminal slots. A target that cannot be read or rendered is `failed` and lands no file; the others go on.
3. **Stage and swap.** Apply removes a `next-theme/` or `old-theme/` a crashed or refused apply left, then writes `theme.json`, `terminal.json` and every rendered target file into `next-theme/`, the sibling of `theme/`. Each file is created exclusively. A rename cannot replace a non-empty directory, so `theme/` moves to `old-theme/`, `next-theme/` becomes `theme/` and `old-theme/` is removed. `theme/` is absent between the two renames; a failed second rename moves the old one back. Then `theme.name` holds the package name.
4. **Wiring.** Each landed target's include line is kept in its application's configuration file, on every apply, unchanged bytes included, so a hand edit that drops it is repaired. A symlink is resolved and the file it names is replaced by rename with its mode kept, so a dotfile manager's link stays a link. An absent file is created only when `create` is `true`, never through a dangling symlink. A file that cannot be read or written fails its target. The include line is the only write outside the state directory and the theme file.
5. **Theme file.** Last, the package's `theme.json` bytes replace `${XDG_CONFIG_HOME:-~/.config}/vgs/theme.json` by rename, so the shell restyles after every application file is in place and never reads half a file. The copy is byte for byte: a re-serialised copy would report every apply as modified. A file already holding those bytes is not written.

The result is `{ state, shell, targets, theme, reason }`.

| Field | Values |
|---|---|
| `shell` | `applied`, `unchanged` when the file already held the bytes, or `failed` when writing it failed. |
| `targets[]` | `{ name, state, reason }` per shipped target, in name order. `state` is `written`, `unchanged` when every file already held its bytes, `skipped` with `reason` `disabled`, `not-detected` or `wiring-file-absent`, or `failed` with the renderer's reason, `unreadable` or `unwritable`. |
| `state` | `partial` when a target failed; else `applied` when the shell or a target took new bytes; else `unchanged`. A refusal is `failed`. |
| `reason` | Null, or a refusal's key: `malformed-name`, `busy`, `lock-failed`, `unknown`, `unwritable`, `unreadable`, `unparseable`, `malformed`, `terminal-fallback` or the package's own. `targets` is `[]` for a refusal before the swap. |

Text mode prints `target=<name> state=<state>[ reason=<key>]` per target, then `ok theme=<name> state=<state> shell=<shell>`, or `partial ...` for a partial apply. `--json` prints the result as one line, refusals included. Each refusal prints `vgsh: refused: theme=<name> reason=<key>` on stderr, a malformed name JSON-quoted, and each failed target `vgsh: refused: target=<name> reason=<key> <detail>`. Exit 0 for `applied` and `unchanged`, 3 for `partial`, 1 on a refusal, 75 when busy, 2 on a bad invocation.

[D021](../decisions/D021-theme-apply-writes-beside-each-destination.md) records why every write is staged beside its destination and the shell document comes last.

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
8. Apply lands each enabled target's files in `theme/` with its encoder, skips a disabled, undetected or unwired target, and never runs a detect command; a target that fails to render lands no file and costs only itself, and the apply is `partial` with exit 3; the include line is kept first in the file, through a symlink with its mode, on unchanged bytes too; a `shell.json` the config judge refuses refuses the apply. Enforced by `scripts/test-vgsh.sh` under a PATH of stub commands, with a symlink-replacing and a written-only judge copy as its controls.
9. The target and template rules: [theme-targets.md § Invariants](theme-targets.md#invariants).
10. The `theme` capability rules: [theme-capability.md § Invariants](theme-capability.md#invariants).
11. Add lands a package under its document name from a staging directory and refuses a package the judge refuses, the reserved `vgs` and `targets`, a source without `theme.json` and an occupied name, leaving nothing behind; update fast-forwards, refuses a modified checkout and a rewritten history, and rolls back a refused or renamed version; remove deletes only an installed directory; none runs a git hook; each is refused busy while the theme lock is held; and no git call inherits the lock's descriptor. Enforced by `scripts/test-vgsh.sh`, with copies of `bin/vgsh` whose install verbs take no lock and whose git calls keep the descriptor as its controls.
