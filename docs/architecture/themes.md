# Themes

Covers: themes/**, bin/vgsh-theme-judge, bin/lib/judge-files.js, scripts/test-vgsh-theme-judge.js, scripts/test-judge-files.js

A theme package is one directory. It holds the shell document and the application files that later apply steps copy or render. The package judge is pure; callers read files and pass their text to `ThemeLogic.acceptPackage`, and `bin/vgsh-theme-judge` owns the directory walk, the list, the apply and the reload.

## Package shape

| File | Required | Holds |
|---|---|---|
| `theme.json` | yes | The shell document from [design-system.md § The shell document](design-system.md#the-shell-document). |
| `terminal.json` | no | `{ "schemaVersion": 1, "slots": { "color0": "#...", ... "color15": "#..." } }`. |
| `targets/<target>.<ext>` | no | A curated file, taken verbatim in place of the target file the renderer writes to that name, where the target accepts it. An installed package's is dropped on a target whose files run code: [theme-targets.md § Templates](theme-targets.md#templates). |
| `backgrounds/<image>` | no | Background images, which apply makes current: [theme-backgrounds.md](theme-backgrounds.md). |

The directory name is the package name and must equal `theme.json`'s `name`; `ThemeLogic.isPackageName` bounds it to a letter or digit followed by letters, digits, `.`, `_` and `-`. The name `vgs` is reserved for the shipped defaults, so an installed package cannot hide the revert package. A package without `terminal.json` is valid; apply renders the shipped `vgs` terminal slots in its place.

The shipped packages are `vgs`, the dark defaults and the revert, and `light`, the shipped light package. A package states whether it is light or dark in the `scheme.mode` token, which a plugin that owns its look reads ([appearance.md](appearance.md)) and the Zed and VS Code targets mark their themes with ([theme-editors.md](theme-editors.md)); nothing infers a mode from a package's name or colours. `light` sets `scheme.mode`, the seven palette colours and `color.textFaint`, with its own `terminal.json`. The default faint mix, 0.42 of the way to the background, gives faint text a WCAG contrast of 3.89:1 on the light `color.surface`. At 0.36 the ratio is 4.76:1, beside the 4.79:1 `vgs` draws. Each ratio is `ThemeLogic.luminance` over the resolved tokens, computed under node on 2026-09-27.

## Package sources

A package is shipped under `themes/<name>/`, installed under the configuration home, or listed in the catalog under `themes/catalog/`, whose packages offline validation judges as the installed packages they become: [theme-catalog.md](theme-catalog.md).

## Boundaries

- `ThemeLogic.acceptPackage` takes the token table and file texts. It performs no I/O. It judges `theme.json` through `ThemeLogic.accept`, judges terminal slot names and colours, checks the directory/document name match, and applies the `vgs`, `targets`, `catalog` and `thumbnails` reservations.
- `bin/vgsh-theme-judge` walks the package and target directories, reads every file an apply needs, and makes every decision through `ThemeLogic.js`, `Tokens.js` and, for `shell.json`, `PluginLogic.js`, loaded through `bin/lib/qml-library.js`. Its refusal and its file writes are `bin/lib/judge-files.js`, shared with `bin/vgsh-plugin-judge`.
- `bin/lib/theme-render.js` judges `target.json`, renders templates and chooses the terminal slots. It performs no I/O: the judge reads every file and passes its text or bytes, with `ThemeLogic.js` and the token table as arguments, so a token path means what it means to the shell.
- `bin/lib/theme-select.js` decides the text a settings file takes when a target's `select` sets its theme key. It performs no I/O either.
- `shell/Core/ThemeRunner.qml` owns the `vgsh theme` processes behind the `theme` capability, a queue and a download lane: [theme-capability.md](theme-capability.md). It starts runner commands and reports their structured result; it judges no package file itself.
- `shell/plugins/vgs.themes/**` belongs to [theme-capability.md § Plugin](theme-capability.md#plugin). This topic covers package and core runner contracts only.

## Runner

`vgsh theme list [--json]`, `vgsh theme apply [--json] <name>`, `vgsh theme follow [--json]` and `vgsh theme reload [--json]` work with no shell running and never contact one. `bin/vgsh` parses the command line and takes the lock; `bin/vgsh-theme-judge` does the rest.

- **Packages.** Shipped packages are `themes/<name>/`, installed ones `${XDG_CONFIG_HOME:-~/.config}/vgs/themes/<name>/`; a symlink to a directory counts. An installed package hides the shipped package of its name, which is listed as `shadowed` and never read, even when the installed one is refused. An installed `vgs` is refused `reserved-name`, even when its files cannot be read, and hides nothing, so `apply vgs` always takes the shipped defaults.
- **List.** One row per package: its source (`shipped`, `installed`), its state (`ok`, `refused` with the judge's reason key, or `shadowed`), whether it is the theme file's named package and, when `ok`, its resolved `palette` group. The theme file's state is read from disk with `ThemeLogic.accept`, in `ThemeSource`'s vocabulary: `loaded`, `absent`, `refused`, `unreadable`. `modified` is `false` when the named package is accepted and the file holds either its `theme.json` bytes or the bytes the last apply of that package wrote, which `applied.json` records ([theme-follow.md](theme-follow.md)), so a file a follow has yet to replace is unmodified. It is `false` for an absent file, `true` for any other loaded file, a refused file and one no accepted package names, and `null` for an unreadable one. A record that cannot be read or judged refuses the list with `vgsh: refused: themes=<reason> path=<record>`, `unreadable` adding the error code. `--json` prints `{ file: { path, state, name, modified }, packages: [{ name, source, path, state, reason, current, palette }] }` as one line.
- **Lock.** `apply`, `follow` and `reload` hold `flock` on `${XDG_CONFIG_HOME:-~/.config}/vgs/theme.lock`, beside the file it guards, so callers with different runtime directories serialise. The configuration directory is created first; the lock file is never removed. `bin/vgsh` holds it on a descriptor the judge inherits, so the lock lasts the whole command. A second apply, follow or reload exits 75 with `reason=busy`; a lock that cannot be opened is `reason=lock-failed`.

[D020](../decisions/D020-theme-apply-swaps-state-and-writes-the-shell-file-last.md) records the lock, the swap and the shadowing rule.

## Install

`vgsh theme add`, `update`, `remove` and `outdated` install and maintain packages under the configuration home, and `vgsh theme install` installs a catalog package there: [theme-install.md](theme-install.md).

## Apply

`vgsh theme apply` and `vgsh theme reload` land a package in the state directory, every enabled target and the shell, and run reload hooks: [theme-apply.md](theme-apply.md) and [theme-reload.md](theme-reload.md). Apply also makes one of the package's background images current, `vgsh theme background next` and `previous` move to the next or the previous one, `set` shows one chosen image on every screen or on one output, and `list` names the images: [theme-backgrounds.md](theme-backgrounds.md). `vgsh theme follow` applies the applied package again once it changed: [theme-follow.md](theme-follow.md).

## Trust

A curated target file is written verbatim into a path an application includes. On a target whose files load or run code, its `target.json` `runsCode`, an installed package's curated file is dropped and the template rendered in its place, so a theme someone shared, or an update of it, runs none of its author's code. Lua, Emacs Lisp, a terminal configuration naming the program it launches, a shell `command` module and a VS Code extension are code. A shipped package keeps its curated files, and an installed package keeps them on every other target. The dropped file is not judged: `renderTarget` lists its destination in `dropped`, and the apply names it on the target's row, which keeps it when the target's wiring or reload then fails: [theme-apply.md § Apply](theme-apply.md#apply). A target without `runsCode` is refused. No package contributes a symlink below its own directory, as Omarchy drops every symlink from a cloned theme: a symlinked curated file, or a symlinked `targets/`, is dropped and named on the row like any drop, a symlinked image or `backgrounds/` holds no image, and a symlinked `theme.json` or `terminal.json` refuses the package `symlink`; the package directory itself may be a symlink, and the shipped packages carry none. [D019](../decisions/D019-theme-packages-carry-plugin-trust.md) records the package boundary and [D031](../decisions/D031-installed-themes-render-code-targets.md) the drop.

## Invariants

1. The shipped `vgs` package is accepted, and an installed package named `vgs`, a directory name `isPackageName` refuses, a directory/document name mismatch, a bad terminal slot name and a bad terminal colour are refused. Enforced by `scripts/test-theme-logic.js`.
2. Every package under `themes/` passes the package judge in offline validation. Enforced by `bin/vgsh-theme-judge packages themes`, selected by `scripts/validate` for `themes/*` changes.
3. The nested smoke sandbox contains the shipped packages beside `shell`, `bin`, `config` and `scripts`. Owned by `scripts/smoke/harness.sh`.
4. An installed package shadows the shipped package of its name, and an installed `vgs` shadows nothing. Enforced by `scripts/test-vgsh.sh`.
5. The list reports a refused package with its reason and the theme file's state from disk; apply refuses a refused package. Enforced by `scripts/test-vgsh.sh`. `modified` is false for the file's package bytes and for the bytes `applied.json` records for it, and true for a hand edit. Enforced by `scripts/test-vgsh-follow.sh`, with a judge copy that ignores the record as its control.
6. A second apply is refused with `reason=busy` while the lock is held. Enforced by `scripts/test-vgsh.sh`, with a lockless `bin/vgsh` copy as its control.
7. The target and template rules: [theme-targets.md § Invariants](theme-targets.md#invariants), the editor targets': [theme-editors.md § Invariants](theme-editors.md#invariants), and the browser targets': [theme-browsers.md § Invariants](theme-browsers.md#invariants).
8. The apply and reload rules: [theme-apply.md § Invariants](theme-apply.md#invariants) and [theme-reload.md § Invariants](theme-reload.md#invariants), and the follow rules: [theme-follow.md § Invariants](theme-follow.md#invariants).
9. The `theme` capability rules: [theme-capability.md § Invariants](theme-capability.md#invariants).
10. The background rules: [theme-backgrounds.md § Invariants](theme-backgrounds.md#invariants).
11. An installed package's curated `neovim.lua`, `kitty.conf` and `alacritty.toml` are dropped and named on their rows, in JSON and in text, and the drop stays on a row whose wiring or reload fails; a shipped package's `neovim.lua` lands byte for byte; a target without `runsCode` fails with `missing=runsCode`. Enforced by `scripts/test-vgsh-targets.sh`, with judge copies that take every package as shipped, report no drop in JSON or in text and lose the drop on a failed reload or wiring, and a renderer copy that does not require the key, as its controls. The renderer's drop rules are [theme-targets.md § Invariants](theme-targets.md#invariants).
12. `replaceFile` in `bin/lib/judge-files.js` creates the staging copy of a file kept with a mode owner-only, a stale one of its process removed first, and gives it that mode only once it is full. Enforced by `scripts/test-judge-files.js`, whose controls drop the owner-only creation, the stale removal and the kept mode from a copy of the helper.
13. A symlinked curated file and a file under a symlinked `targets/` are dropped and named on a target that runs no code, a regular curated file there lands byte for byte, a symlinked `theme.json` or `terminal.json` is refused `symlink` by list, apply and the install judge, and follow sees no change behind a link. Enforced by `scripts/test-vgsh-package-links.sh`, with judge copies that follow a link, drop it unreported, never refuse a linked package file at list or at install, and digest a linked file or `targets/`, as its controls.
14. The install rules: [theme-install.md § Invariants](theme-install.md#invariants), the catalog install rules: [theme-catalog.md § Invariants](theme-catalog.md#invariants), and the wallpaper download rules: [theme-wallpapers.md § Invariants](theme-wallpapers.md#invariants).
15. `main` in `bin/lib/judge-files.js` ends a process on a refusal with its keyed line, then its detail, and its status, whether the command throws the refusal or returns a promise that rejects with it. Enforced by `scripts/test-judge-files.js`, whose controls drop the detail and the promise's handler from a copy of the helper.
