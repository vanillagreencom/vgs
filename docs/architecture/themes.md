# Themes

Covers: themes/**, bin/vgsh-theme-judge, bin/lib/judge-files.js, bin/lib/theme-render.js, scripts/test-vgsh-theme-judge.js, scripts/test-theme-render.js, shell/Core/ThemeRunner.qml, scripts/smoke/rows/themes.sh

A theme package is one directory. It holds the shell document and the application files that later apply steps copy or render. The package judge is pure; callers read files and pass their text to `ThemeLogic.acceptPackage`, and `bin/vgsh-theme-judge` owns the directory walk, the list and the apply.

## Package shape

| File | Required | Holds |
|---|---|---|
| `theme.json` | yes | The shell document from [design-system.md § The shell document](design-system.md#the-shell-document). |
| `terminal.json` | no | `{ "schemaVersion": 1, "slots": { "color0": "#...", ... "color15": "#..." } }`. |
| `targets/<target>.<ext>` | no | A curated file, taken verbatim in place of the target file the renderer writes to that name: [§ Templates](#templates). |

The directory name is the package name and must equal `theme.json`'s `name`; `ThemeLogic.isPackageName` bounds it to a letter or digit followed by letters, digits, `.`, `_` and `-`. The name `vgs` is reserved for the shipped defaults, so an installed package cannot hide the revert package. A package without `terminal.json` is valid; apply renders the shipped `vgs` terminal slots in its place.

The shipped packages are `vgs`, the dark defaults and the revert, and `light`, the shipped light package. The format holds no light or dark field, so a surface that offers a light mode picks `light` by name. `light` sets the seven palette colours and `color.textFaint`, with its own `terminal.json`. The default faint mix, 0.42 of the way to the background, gives faint text a WCAG contrast of 3.89:1 on the light `color.surface`. At 0.36 the ratio is 4.76:1, beside the 4.79:1 `vgs` draws. Each ratio is `ThemeLogic.luminance` over the resolved tokens, computed under node on 2026-09-27.

## Boundaries

- `ThemeLogic.acceptPackage` takes the token table and file texts. It performs no I/O. It judges `theme.json` through `ThemeLogic.accept`, judges terminal slot names and colours, checks the directory/document name match, and applies the `vgs` reservation.
- `bin/vgsh-theme-judge` walks the package directories, reads `theme.json` and `terminal.json` and the theme file, and makes every decision through `ThemeLogic.js` and `Tokens.js`, loaded through `scripts/qml-library.js`. Its refusal and its file writes are `bin/lib/judge-files.js`, shared with `bin/vgsh-plugin-judge`.
- `bin/lib/theme-render.js` judges `target.json`, renders templates and chooses the terminal slots. It performs no I/O: the judge reads every file and passes its text or bytes, with `ThemeLogic.js` and the token table as arguments, so a token path means what it means to the shell.
- `shell/Core/ThemeRunner.qml` owns the `vgsh theme` process behind the `theme` capability, [§ Capability](#capability). It starts runner commands and reports their structured result; it judges no package file itself.
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

## Install

`vgsh theme add <git url>`, `vgsh theme update <name>` and `vgsh theme remove <name>` install, fast-forward and delete packages under `${XDG_CONFIG_HOME:-~/.config}/vgs/themes/`. They share the git handling of `vgsh plugin add`, `update` and `remove` ([manager.md](manager.md)): no git hook, no submodule and no package file runs, and no privilege is asked for. They never contact the shell. `bin/vgsh-theme-judge accept` judges a package through `ThemeLogic.acceptPackage`, and `bin/vgsh-theme-judge installed` resolves the directory update and remove act on.

- **Add.** The clone lands in a staging directory beside `themes/`, so no list reads half a package. The package's name is its `theme.json` document name, read by `ThemeLogic.accept`. The judge then accepts the package under that name as an installed one, so the reserved `vgs`, a name `isPackageName` refuses and a bad terminal file are refused. `targets` is refused `reserved-name`, since a themes directory's `targets/` is never read as a package. A source without `theme.json` is refused `absent`. An occupied `themes/<name>` is refused `exists`. An add may shadow a shipped package of its name, as [§ Runner](#runner) lists it, and its line then names the shipped path: `ok added=<name> path=<dir>[ shadows=<shipped dir>]`.
- **Update.** Update refuses a checkout with local changes or untracked files, prints the incoming diff and fast-forwards only. A version the judge refuses under the installed name, a renamed document included, is rolled back before the refusal. The package the theme file names keeps its applied bytes until the next `theme apply`, so `theme list` reports the file `modified`.
- **Remove.** Remove deletes `themes/<name>`, an installed `vgs` included, and never a shipped package, a symlink or a file.
- **Resolution.** Update and remove refuse a name `isPackageName` refuses as `malformed-name`, `targets` as `reserved-name`, a name only a shipped package has as `shipped`, and any other absent name as `unknown`.
- **Lock.** Each verb holds the `theme.lock` apply holds, from before it changes `themes/` until it exits, so no apply reads a package mid-change. Add takes it after the clone and the judge. No git call inherits its descriptor, so a gc git detaches never holds it. A held lock exits 75 with `vgsh: refused: theme=<name> reason=busy`, and an apply started meanwhile is refused `reason=busy`.
- **Refusals.** A judge refusal prints `vgsh: refused: package=<url> reason=<key> ...` on add and `vgsh: refused: theme=<name> reason=<key> ... rolled-back=<commit>` on update. Every other refusal names `theme=<name> reason=<key>`, or the git key the plugin verbs use. Exit 0, 1 on a refusal, 75 when busy, 2 on a bad invocation; the verbs take no `--json`.

## Targets

A target is one application's colour files: the directory `themes/targets/<target>/`, holding `target.json` and its templates. A target name is lower-case letters, digits and `-`, with no dot. `targets` under a themes directory holds targets and is never read as a package.

`acceptTarget` in `bin/lib/theme-render.js` judges `target.json`. Every key is required and any other key is refused with `reason=target-schema`:

| Key | Holds |
|---|---|
| `app` | The application's name, one line. |
| `encoder` | The encoder every colour placeholder of the target is written with: [§ Templates](#templates). |
| `files` | One or more `{ template, destination }`. `template` is a file name in the target directory other than `target.json`. `destination` is the file name the render takes under the state directory's `theme/`: `<target>.<ext>`, unique in the target, so no two targets write one file. |
| `detect` | Command names; a target whose command is absent is skipped. An empty list is always detected. |
| `wiring` | `{ file, line, create }`. `file` is the application's configuration file, relative to `${XDG_CONFIG_HOME:-~/.config}`, each segment a plain directory name. `line` is the one include line kept in that file; its only placeholder is `@{state}`, the state directory's `theme/` path, which it must hold. `create` is `true` when an absent `file` is created holding the line, `false` when the target is then skipped with reason `wiring-file-absent`. |
| `reload` | `null`, or `{ command, timeoutMs }`: the argv that makes a running application re-read its files, and its bound in whole milliseconds. |

`bin/vgsh-theme-judge packages themes`, the offline row, renders every target under `themes/targets/` against the shipped `vgs` package and prints one line per target, `ok       targets/<target>` or `refused  <dir>: target=<target> reason=<key> <detail>`. A template or `target.json` that cannot be read, or targets without an accepted `vgs` package holding terminal slots, exit 2.

## Templates

`renderTarget` renders every file of an accepted target from the package's resolved token values, the terminal slots and the package's curated files.

- **Placeholders.** `@{<path>}` is a token of the table and `@{terminal.color<N>}` a terminal slot, `color0` to `color15`. `@@{` is a literal `@{`. Every other character passes through, so `#{pane_id}` and `${HOME}` render whole.
- **Refusal.** A placeholder that names no token and no slot, a group included, refuses the target with `reason=placeholder template=<file> placeholder="<name>"`; a `@{` with no `}` after it refuses with `unterminated=<offset>`. The target renders no file.
- **Values.** A colour token and a slot are written through the target's encoder. Any other token is written as its resolved value: `@{space.sm}` is `6`.
- **Curated files.** A package's `targets/<destination>` is taken byte for byte in place of the rendered file of that destination. The template is rendered all the same, so a curated file never hides a bad placeholder.
- **Terminal slots.** `terminalSource` takes the package's own `terminal.json`, else the shipped `vgs` package's. `apply` writes the same package's `terminal.json` into the state directory.

Encoders, each shown for `#ff5a3659`:

| Encoder | Writes | Example |
|---|---|---|
| `hex6` | `rrggbb`, alpha dropped | `ff5a36` |
| `hex8` | `rrggbbaa` | `ff5a3659` |
| `rgba` | `rgba(r, g, b, a)`, channels 0 to 255, alpha 0 to 1 to three decimals | `rgba(255, 90, 54, 0.349)` |
| `hyprland` | `rgba(rrggbbaa)` | `rgba(ff5a3659)` |

No encoder writes `#`: a template writes it where its application wants one, as `#@{palette.accent}`.

## Capability

`shell.theme`, for a plugin naming `theme`, lists and applies packages; token values stay on `Theme`. `shell/Core/ThemeRunner.qml` owns the one `vgsh theme` process, started as `Quickshell.shellDir + "/../bin/vgsh"`, the jobs waiting for it, the last list and the last apply result. [`api.md` § The shell object](../../.agents/skills/vgs-plugin/references/api.md#the-shell-object) lists the members.

- **Queue.** One job runs at a time. A list asked for while the last queued job is a list joins it. `apply` answers `refused: theme=<name> reason=busy` at once while another apply runs or waits, and `refused: theme=<name> reason=malformed-name`, the name JSON-quoted, for a name `ThemeLogic.isPackageName` refuses; every other refusal arrives in `done`, since the judge makes it. A job starts after the call that queued it returns, so `done` never runs before `apply` answers.
- **Results.** The runner's JSON line is the answer whatever the exit code, so a refusal's exit 1 and a held lock's 75 reach `done` as results. A process that fails to start emits only `runningChanged` ([runtime.md § QML](runtime.md#qml)) and answers `{ state: failed, shell: failed, targets: [], theme, reason: start-failed }`; an exit without a readable line answers the same with `reason: output-unreadable`. Both are logged as `theme: vgsh theme <verb> reason=<key>`. A list answers `{ file, packages, reason }`: `reason` is null when the runner printed the list, and `file` and `packages` are null beside the reason otherwise.
- **Lifetimes.** Each `done` is registered in its instance's lifetime: a destroyed instance's callback is dropped and its job still runs, so an apply always completes. `last` is `{ applying, result }`, `applying` the name of the apply running or waiting, or null. It lives in the runner, so a panel closed during an apply and reopened after it reads the result.
- **Readings.** `swatch(name)` is the `ok` package's `palette` from the last list, each colour through `Theme.toColor`; a refused, shadowed or unknown package has none. `modified` is the last list's `file.modified`. Both are null before the first list and after a failed one. `current`, `revision` and `fileState` are `Theme.name`, `Theme.revision` and `Theme.fileState`. `done` can run before `ThemeSource` reloads the file, so a caller that needs the new theme waits on `revision`.

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
8. Each encoder's output, the `@@{` escape, the pass-through of `#{pane_id}`, the refusal of a placeholder naming no token or slot, every `target.json` rule, the curated precedence and the terminal fallback hold. Enforced by `scripts/test-theme-render.js`, whose controls remove one rule each from a copy of the renderer.
9. Every placeholder of every target under `themes/targets/` names a token or a slot, and `targets/` is not listed as a package. Enforced by `bin/vgsh-theme-judge packages themes` and `scripts/test-vgsh-theme-judge.js`, and for list and apply by `scripts/test-vgsh.sh`.
10. Through the `theme` capability a plugin applies a package and then reads `current` and `revision` move, lists every package with its state, reads a swatch alpha first and `modified` after a hand edit and `fileState` after a refused one; is refused busy and malformed at once; receives a refusal's non-zero exit as its result, an unreadable result and a failed start as failures; and a destroyed instance's callbacks are dropped while its apply completes into `last`, which the rebuilt instance reads. Enforced by `scripts/smoke/rows/themes.sh` through the `acme.probe` fixture, with the sandbox's `vgsh` replaced by stand-ins for the held, unreadable and unstartable runs.
11. Add lands a package under its document name from a staging directory and refuses a package the judge refuses, the reserved `vgs` and `targets`, a source without `theme.json` and an occupied name, leaving nothing behind; update fast-forwards, refuses a modified checkout and a rewritten history, and rolls back a refused or renamed version; remove deletes only an installed directory; none runs a git hook; each is refused busy while the theme lock is held; and no git call inherits the lock's descriptor. Enforced by `scripts/test-vgsh.sh`, with copies of `bin/vgsh` whose install verbs take no lock and whose git calls keep the descriptor as its controls.
12. Applying the shipped `light` package through the `theme` capability restyles every section of the gallery. One example per section is read back as a property through the probe's `galleryColour`, never a drawn frame. Each colour equals the token `ThemeLogic.accept` resolves from `themes/light/theme.json` and differs from the `vgs` default. Enforced by `scripts/smoke/rows/themes.sh`, which applies `vgs` after it.
