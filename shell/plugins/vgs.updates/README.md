# Updates

`vgs.updates` is the service that owns update checks for VGS.

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

TERM, INT or HUP to `bin/check` signals every probe's process group and waits for each probe to exit. A probe ends its own git fetch before it exits: [manager.md § Outdated](../../../docs/architecture/manager.md#outdated).

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

## Validation

`scripts/test-updates-logic.js` pins every decision in `UpdatesLogic.js` with a control. `scripts/test-updates-check.sh` pins `bin/check`'s argv, concurrency and signal handling. `scripts/smoke/rows/updates.sh` runs the service in the nested sandbox against stand-in package managers and git.

## Later issues

VGS-553 adds the bar widget and flyout kinds.

VGS-554 adds the update TUI entries and scripts.
