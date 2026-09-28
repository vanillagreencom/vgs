# Themes

Covers: themes/**, bin/vgsh-theme-judge, bin/lib/judge-files.js, scripts/test-vgsh-theme-judge.js

A theme package is one directory. It holds the shell document and the application files that later apply steps copy or render. The package judge is pure; callers read files and pass their text to `ThemeLogic.acceptPackage`, and `bin/vgsh-theme-judge` owns the directory walk, the list, the apply and the reload.

## Package shape

| File | Required | Holds |
|---|---|---|
| `theme.json` | yes | The shell document from [design-system.md § The shell document](design-system.md#the-shell-document). |
| `terminal.json` | no | `{ "schemaVersion": 1, "slots": { "color0": "#...", ... "color15": "#..." } }`. |
| `targets/<target>.<ext>` | no | A curated file, taken verbatim in place of the target file the renderer writes to that name, where the target accepts it: [theme-targets.md § Templates](theme-targets.md#templates). |

The directory name is the package name and must equal `theme.json`'s `name`; `ThemeLogic.isPackageName` bounds it to a letter or digit followed by letters, digits, `.`, `_` and `-`. The name `vgs` is reserved for the shipped defaults, so an installed package cannot hide the revert package. A package without `terminal.json` is valid; apply renders the shipped `vgs` terminal slots in its place.

The shipped packages are `vgs`, the dark defaults and the revert, and `light`, the shipped light package. A package states whether it is light or dark in the `scheme.mode` token, which a plugin that owns its look reads ([appearance.md](appearance.md)); nothing infers a mode from a package's name or colours. `light` sets `scheme.mode`, the seven palette colours and `color.textFaint`, with its own `terminal.json`. The default faint mix, 0.42 of the way to the background, gives faint text a WCAG contrast of 3.89:1 on the light `color.surface`. At 0.36 the ratio is 4.76:1, beside the 4.79:1 `vgs` draws. Each ratio is `ThemeLogic.luminance` over the resolved tokens, computed under node on 2026-09-27.

## Boundaries

- `ThemeLogic.acceptPackage` takes the token table and file texts. It performs no I/O. It judges `theme.json` through `ThemeLogic.accept`, judges terminal slot names and colours, checks the directory/document name match, and applies the `vgs` reservation.
- `bin/vgsh-theme-judge` walks the package and target directories, reads every file an apply needs, and makes every decision through `ThemeLogic.js`, `Tokens.js` and, for `shell.json`, `PluginLogic.js`, loaded through `scripts/qml-library.js`. Its refusal and its file writes are `bin/lib/judge-files.js`, shared with `bin/vgsh-plugin-judge`.
- `bin/lib/theme-render.js` judges `target.json`, renders templates and chooses the terminal slots. It performs no I/O: the judge reads every file and passes its text or bytes, with `ThemeLogic.js` and the token table as arguments, so a token path means what it means to the shell.
- `shell/Core/ThemeRunner.qml` owns the `vgsh theme` process behind the `theme` capability: [theme-capability.md](theme-capability.md). It starts runner commands and reports their structured result; it judges no package file itself.
- `shell/plugins/vgs.themes/**` belongs to [theme-capability.md § Plugin](theme-capability.md#plugin). This topic covers package and core runner contracts only.

## Runner

`vgsh theme list [--json]`, `vgsh theme apply [--json] <name>` and `vgsh theme reload [--json]` work with no shell running and never contact one. `bin/vgsh` parses the command line and takes the lock; `bin/vgsh-theme-judge` does the rest.

- **Packages.** Shipped packages are `themes/<name>/`, installed ones `${XDG_CONFIG_HOME:-~/.config}/vgs/themes/<name>/`; a symlink to a directory counts. An installed package hides the shipped package of its name, which is listed as `shadowed` and never read, even when the installed one is refused. An installed `vgs` is refused `reserved-name`, even when its files cannot be read, and hides nothing, so `apply vgs` always takes the shipped defaults.
- **List.** One row per package: its source (`shipped`, `installed`), its state (`ok`, `refused` with the judge's reason key, or `shadowed`), whether it is the theme file's named package and, when `ok`, its resolved `palette` group. The theme file's state is read from disk with `ThemeLogic.accept`, in `ThemeSource`'s vocabulary: `loaded`, `absent`, `refused`, `unreadable`. `modified` compares the file's bytes with the named package's `theme.json`: `false` for an absent file, `true` for a refused file or one no accepted package names, `null` for an unreadable one. `--json` prints `{ file: { path, state, name, modified }, packages: [{ name, source, path, state, reason, current, palette }] }` as one line.
- **Lock.** `apply` and `reload` hold `flock` on `${XDG_CONFIG_HOME:-~/.config}/vgs/theme.lock`, beside the file it guards, so callers with different runtime directories serialise. The configuration directory is created first; the lock file is never removed. `bin/vgsh` holds it on a descriptor the judge inherits, so the lock lasts the whole command. A second apply or reload exits 75 with `reason=busy`; a lock that cannot be opened is `reason=lock-failed`.

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

`vgsh theme apply` and `vgsh theme reload` land a package in the state directory, every enabled target and the shell, and run reload hooks: [theme-apply.md](theme-apply.md).

## Trust

Applying a third-party package carries plugin-level trust. A curated target file is written verbatim into a path an application includes, so package application has the same user-privilege impact as enabling a plugin. [D019](../decisions/D019-theme-packages-carry-plugin-trust.md) records the boundary.

## Invariants

1. The shipped `vgs` package is accepted, and an installed package named `vgs`, a directory name `isPackageName` refuses, a directory/document name mismatch, a bad terminal slot name and a bad terminal colour are refused. Enforced by `scripts/test-theme-logic.js`.
2. Every package under `themes/` passes the package judge in offline validation. Enforced by `bin/vgsh-theme-judge packages themes`, selected by `scripts/validate` for `themes/*` changes.
3. The nested smoke sandbox contains the shipped packages beside `shell`, `bin`, `config` and `scripts`. Owned by `scripts/smoke/harness.sh`.
4. An installed package shadows the shipped package of its name, and an installed `vgs` shadows nothing. Enforced by `scripts/test-vgsh.sh`.
5. The list reports a refused package with its reason, the theme file's state from disk and `modified` by a byte comparison; apply refuses a refused package. Enforced by `scripts/test-vgsh.sh`.
6. A second apply is refused with `reason=busy` while the lock is held. Enforced by `scripts/test-vgsh.sh`, with a lockless `bin/vgsh` copy as its control.
7. The target and template rules: [theme-targets.md § Invariants](theme-targets.md#invariants), and the editor targets': [theme-editors.md § Invariants](theme-editors.md#invariants).
8. The apply and reload rules: [theme-apply.md § Invariants](theme-apply.md#invariants).
9. The `theme` capability rules: [theme-capability.md § Invariants](theme-capability.md#invariants).
10. Add lands a package under its document name from a staging directory and refuses a package the judge refuses, the reserved `vgs` and `targets`, a source without `theme.json` and an occupied name, leaving nothing behind; update fast-forwards, refuses a modified checkout and a rewritten history, and rolls back a refused or renamed version; remove deletes only an installed directory; none runs a git hook; each is refused busy while the theme lock is held; and no git call inherits the lock's descriptor. Enforced by `scripts/test-vgsh.sh`, with copies of `bin/vgsh` whose install verbs take no lock and whose git calls keep the descriptor as its controls.
