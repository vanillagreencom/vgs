# Theme capability

Covers: shell/Core/ThemeRunner.qml, scripts/smoke/rows/themes.sh

The `theme` capability runs the `vgsh theme` commands of [themes.md](themes.md) for a plugin.

## Capability

`shell.theme`, for a plugin naming `theme`, lists and applies packages; token values stay on `Theme`. `shell/Core/ThemeRunner.qml` owns the one `vgsh theme` process, started as `Quickshell.shellDir + "/../bin/vgsh"`, the jobs waiting for it, the last list and the last apply result. [`api.md` § The shell object](../../.agents/skills/vgs-plugin/references/api.md#the-shell-object) lists the members.

- **Queue.** One job runs at a time. A list asked for while the last queued job is a list joins it. `apply` answers `refused: theme=<name> reason=busy` at once while another apply runs or waits, and `refused: theme=<name> reason=malformed-name`, the name JSON-quoted, for a name `ThemeLogic.isPackageName` refuses; every other refusal arrives in `done`, since the judge makes it. A job starts after the call that queued it returns, so `done` never runs before `apply` answers.
- **Results.** The runner's JSON line is the answer whatever the exit code, so a refusal's exit 1, a partial apply's exit 3 and a held lock's 75 reach `done` as results. A process that fails to start emits only `runningChanged` ([runtime.md § QML](runtime.md#qml)) and answers `{ state: failed, shell: failed, targets: [], theme, reason: start-failed }`; an exit without a readable line answers the same with `reason: output-unreadable`. Both are logged as `theme: vgsh theme <verb> reason=<key>`. A list answers `{ file, packages, reason }`: `reason` is null when the runner printed the list, and `file` and `packages` are null beside the reason otherwise.
- **Lifetimes.** Each `done` is registered in its instance's lifetime: a destroyed instance's callback is dropped and its job still runs, so an apply always completes. `last` is `{ applying, result }`, `applying` the name of the apply running or waiting, or null. It lives in the runner, so a panel closed during an apply and reopened after it reads the result.
- **Readings.** `swatch(name)` is the `ok` package's `palette` from the last list, each colour through `Theme.toColor`; a refused, shadowed or unknown package has none. `modified` is the last list's `file.modified`. Both are null before the first list and after a failed one. `current`, `revision` and `fileState` are `Theme.name`, `Theme.revision` and `Theme.fileState`. `done` can run before `ThemeSource` reloads the file, so a caller that needs the new theme waits on `revision`.

## Invariants

1. Through the `theme` capability a plugin applies a package and then reads `current` and `revision` move, lists every package with its state, reads a swatch alpha first and `modified` after a hand edit and `fileState` after a refused one; is refused busy and malformed at once; receives a refusal's non-zero exit and a partial apply's result, a fixture target failing beside one that lands, as its result, an unreadable result and a failed start as failures; and a destroyed instance's callbacks are dropped while its apply completes into `last`, which the rebuilt instance reads. Enforced by `scripts/smoke/rows/themes.sh` through the `acme.probe` fixture, with the sandbox's `vgsh` replaced by stand-ins for the held, unreadable and unstartable runs.
2. Applying the shipped `light` package through the `theme` capability restyles every section of the gallery. One example per section is read back as a property through the probe's `galleryColour`, never a drawn frame. Each colour equals the token `ThemeLogic.accept` resolves from `themes/light/theme.json` and differs from the `vgs` default. Enforced by `scripts/smoke/rows/themes.sh`, which applies `vgs` after it.
