# Updates

`vgs.updates` is the service that owns update checks for VGS.

## Sources

The service runs one script, `bin/check`.

That script composes these read-only commands:

- `vgsh pkg check --json`: system packages, AUR, Flatpak and mise tools.
- `vgsh self status --json`: the VGS checkout, package, Nix install or curl install.
- `vgsh plugin outdated --json`: installed plugin git checkouts.
- `vgsh theme outdated --json`: installed theme git checkouts and catalog installs.

The script writes `${XDG_STATE_HOME}/vgs/updates/status.json` atomically.

The status file has this shape:

```json
{ "checkedAt": 1790650695194, "sources": [], "error": null }
```

Each source keeps its own count, package list and error.

A failed source stays visible with `count: null` and its reason.

## Cadence

The default check interval is six hours.

The service publishes the cached snapshot at startup.

It checks at startup only when the cache is older than the interval.

It schedules the next check from `checkedAt`.

It accepts `vgsh ipc call vgs.updates invoke check ''` for an on-demand check.

It checks again when one of its own TUI runs records a new end in `shell.tui.state`.

A cache older than twice the interval reports a stale check state.

Only one check process runs at a time.

A second request while a check runs queues one more check.

## Status values

The service publishes these status keys:

- `pending`: total updates with numeric counts.
- `lastCheck`: the last check time in whole milliseconds since the Unix epoch.
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

## Later issues

VGS-553 adds the bar widget and flyout kinds.

VGS-554 adds the update TUI entries and scripts.
