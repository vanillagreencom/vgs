# Updates

`vgs.updates` is the service that owns update checks for VGS, and the floating TUIs that run the updates ([§ Update pipeline](#update-pipeline)).

## Sources

The service runs this command with argv only:

```text
bin/check --vgsh <absolute path to vgsh>
```

`bin/check` refuses when `--vgsh` is missing or is not an executable absolute path.

The script holds this lock for the whole check:

```text
${XDG_RUNTIME_DIR}/vgs/updates/check.lock
```

It starts these read-only commands concurrently, each in its own process group:

- `vgsh pkg check --json`: system packages, AUR, Flatpak and mise tools.
- `vgsh self status --json`: the VGS checkout, package, Nix install or curl install.
- `vgsh plugin outdated --json`: installed plugin git checkouts.
- `vgsh theme outdated --json`: installed theme git checkouts and catalog installs.

TERM, INT or HUP to `bin/check` sends TERM to every probe's process group and waits for each probe to exit. A probe starts with SIGINT ignored, as every background job of a shell without job control does, so TERM is the signal each probe acts on. A probe ends its own git fetch before it exits: [manager.md § Outdated](../../../docs/architecture/manager.md#outdated).

It writes this file atomically:

```text
${XDG_STATE_HOME}/vgs/updates/status.json
```

The status file has this shape:

```json
{ "checkedAt": 1790650695194, "sources": [], "error": null }
```

`checkedAt` is whole milliseconds since the Unix epoch.

`sources` is a list of source rows.

Each row is `{ source, label, count, packages, checkedAt, error }`.

A failed source stays visible with `count: null` and its reason in `error`.

The shared status value bounds `packages` to twelve rows per source.

A shared source row adds `more` with the number of package rows omitted.

Package `name`, `old` and `new` text is cut to eighty characters in shared status.

The full package list stays in `status.json`.

`error` is null in every file `bin/check` writes: each probe's failure is its own source row. A check that fails before it writes leaves the last good file unchanged, and the service reports that failure in `checkState`. The service still reads a non-null `error` as a failed check.

## Counts

Package-manager rows count packages.

VGS counts as one update when `vgsh self status --json` reports `behind: true`.

Plugins and themes count one update per checkout or catalog package that is behind.

Their package rows keep the commit count as `behind` for the flyout.

An installed directory that is not its own git checkout, such as a copied plugin, has no upstream and `vgsh plugin update` refuses it too, so it is not an update source and is left out.

A checkout whose fetch failed names itself in the source's `error`; the other checkouts still count.

## Cadence

The default check interval is six hours.

The service publishes the cached snapshot at startup.

It checks at startup only when the cache is older than the interval.

It schedules the next check from `checkedAt`.

It accepts `vgsh ipc call vgs.updates invoke check ''` for an on-demand check.

It checks again when one of its own TUI runs records a new end in `shell.tui.state`.

A cache older than twice the interval reports a stale check state.

A check process failure keeps the last good snapshot and reports a danger state.

After a process failure, the service retries after five minutes.

Only one check process runs at a time.

A second request while a check runs queues one more check.

## Status values

The service publishes these status keys:

- `pending`: total updates with numeric counts.
- `lastCheck`: the last successful snapshot time.
- `checkState`: `ok`, `info`, `warning` or `danger`, with a short reason.
- `sources`: the source rows for the later bar widget and flyout.

The Settings page shows the first three rows as read-only status.

`sources` is data for the later widget and panel.

## IPC

`check` starts a check.

It returns `started` or `queued`.

`status` returns the values currently published through plugin status.

## Privacy and network

The service does not send data itself.

The commands it runs can touch the network:

- `vgsh pkg check --json` can use `checkupdates`, Flatpak remotes and mise registries.
- `vgsh self status --json` can fetch the VGS upstream or query the GitHub release API.
- `vgsh plugin outdated --json` fetches installed plugin git upstreams.
- `vgsh theme outdated --json` fetches installed theme git upstreams.

The shell never elevates for a check.

## Omarchy comparison

Omarchy's `SystemUpdate.qml` checks at startup, every six hours and after an update run.

VGS uses the same cadence.

Omarchy checks only whether Omarchy itself has an update.

VGS counts every source because the badge represents the whole system.

## Update pipeline

The plugin declares two floating TUIs.

- `update` runs `tui/update.sh`: every source in one run. Its launcher entry is in the `Update` group, so the launcher's Update row opens it.
- `update-source` runs `tui/update-source.sh <source>`: one source. `<source>` is a status row's `source`: the primary package manager's id, `aur`, `flatpak`, `mise`, `vgs`, `plugins` or `themes`. It is not listed, because it needs its argument: `shell.tui.run("update-source", [source])` opens it.

Both take `-y`, which skips the start question only. They share `tui/pipeline.sh`, whose header is the full contract. A run takes these steps in this order:

1. The log and the lock. `script` writes the run to `${XDG_STATE_HOME}/vgs/updates/update.log`. The lock is `${XDG_RUNTIME_DIR}/vgs-tui-updates.lock`. A second run exits 75 and leaves the first run's log as it is.
2. A warning when `/` has less than 10 GiB free.
3. The plan box: the snapshot tool, each source with the commands it runs, and the log path. Then `Start the update?`, unless `-y`.
4. One sudo session, when a snapshot or the system step needs root. `vgsh pkg run` joins it, so the password is asked once.
5. A snapshot through snapper, else timeshift, unless the `snapshot` setting is `off`. No tool on `PATH` skips quietly. A tool that fails or has no configuration prints a warning, and the update continues without a snapshot.
6. VGS itself: `vgsh self update` for a checkout or a curl install. It restarts a running shell. The `vgs` package updates with its package manager, and a Nix tree with its flake.
7. The system: `vgsh pkg run upgrade --manager <primary>`.
8. Flatpak and mise: `vgsh pkg run upgrade --manager flatpak`, then `--manager mise`.
9. Each plugin, then each theme, that is behind its upstream: `vgsh plugin update <id>` and `vgsh theme update <name>`. Each shows its diff and asks `[y/N]`. The pipeline passes `--yes` only when `trustPluginUpdates` is on. A declined or failed update prints a warning and the run continues.
10. The end of the sudo session. The credential is dropped.
11. The AUR, last: the `aurCommand` setting's words, else `vgsh pkg run upgrade --manager aur` (`paru -Sua` or `yay -Sua`). No AUR build runs under the update's credential. When VGS is the `vgs-git` package and behind, `<helper> -S vgs-git` follows, because an AUR helper rebuilds a `-git` package only when its recipe's version changes. Then the credential is dropped again.
12. On pacman, the orphaned packages from `pacman -Qtdq`, with `Remove N orphaned package(s)?`, default no. A yes runs `vgsh pkg run remove --manager pacman`.
13. A shell restart, when a package step replaced the VGS package.
14. A reboot question, when the kernel or the running Hyprland binary was replaced (`vgs_tui_reboot_check`).

Every package step is the package table's own plan, from `vgsh pkg plan upgrade <id>`. The steps take no `-y`, so each manager asks its own questions in the terminal. A package source without an upgrade plan, such as `nix`, is left out of the run with the reason in the plan box.

With `-y`, the orphan list and the reboot reason are printed instead of asked.

A failing step stops the run. The terminal then shows `updates: failed exit=<n> log=<file>` and how to recover. The sudo session drops the credential on the way out.

The TUIs read the plugin's settings with `vgsh plugin settings vgs.updates`, since `shell.tui.open` hands a script no arguments. `bin/facts` reads each `vgsh` JSON answer for the shell script. It decides whether VGS, a plugin or a theme is behind through `UpdatesLogic.js`, as the service does.

When a run ends, the service checks again ([§ Cadence](#cadence)).

### Omarchy comparison

`bin/omarchy-update` (basecamp/omarchy `e332dc97`) is the model. VGS takes its order and its safety steps: the `script` log, the lock, the free-space check, the confirm box, one sudo authorization with a keepalive, the snapshot with 127 as a quiet skip, mise with `MISE_MINIMUM_RELEASE_AGE=0`, the credential dropped before the AUR, the orphan question with default no, and the reboot question for a new kernel or a replaced Hyprland. `OMARCHY_UPDATE_SUDO_SESSION` is the model for the nested session that `vgsh pkg run` joins.

VGS differs in these ways:

- Low free space is a warning, not a refusal, so a user with a small disk can still update. Omarchy refuses below 10 GiB.
- The package steps are the package table's plans, with no `--noconfirm`, so each manager asks its own questions.
- Each plugin and theme update shows its diff and asks.
- The AUR runs after the credential is dropped, and it is dropped again after. The `sudo-no-update` wrapper is not copied.
- Not copied: migrations, the keyring step, channels and the ALPM guard. These are distribution work, and VGS is not the distribution. The stay-awake step is not copied yet. A later `systemd-inhibit` step can add it.

## Validation

`scripts/test-updates-logic.js` pins every decision in `UpdatesLogic.js` with a control. `scripts/test-updates-check.sh` pins `bin/check`'s argv, concurrency and signal handling. `scripts/test-updates-pipeline.sh` runs the update TUIs on a pseudo-terminal against stand-in commands. It pins the order and argv of every step, `--yes` only with `trustPluginUpdates`, the quiet skip on 127, the recovery message, the orphan and reboot questions, and the busy lock. Its controls include a copy that runs the AUR before the sudo session ends and a copy that always passes `--yes`. `scripts/smoke/rows/updates.sh` runs the service in the nested sandbox against stand-in package managers and git.

## Later issues

VGS-553 adds the bar widget and flyout kinds.
