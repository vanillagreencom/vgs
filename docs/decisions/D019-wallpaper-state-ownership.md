# D019: The shell owns the wallpaper on screen; the helper owns the palette's input

[← Decision Index](INDEX.md)

**Date**: 2026-09-14 **Status**: Active **Research**: —

## Summary

Three cancelled patch proposals (VGS-211 serialize wallpaper mutations, VGS-213 give per-monitor assign one verified owner, VGS-220 reap the thumbnail sweep's temp files) all asked the same unanswered question: who owns wallpaper state, in what order is it written, and what happens when two actors touch it at once. This records the answer, and the two places the pipeline did not already hold to it.

## The pipeline

| Entry point | Calls | Writes |
|---|---|---|
| Wallpaper switcher, Dash Wallpapers, Settings Themes | `VGSThemeService.setWallpaper` → `vshell theme set-wallpaper` | helper: theme package data and the `{wallpaper}` targets; shell: `SessionData` |
| Theme switcher, Dash Themes, Settings Themes, Icons tab, catalog download | `VGSThemeService.applyBlueprint` → `vshell theme apply` | the same, plus every other target |
| Switcher "This monitor", Dash per-monitor buttons, Settings toggle, `wallpaper` IPC | `SessionData.setMonitorWallpaper` and `setPerMonitorWallpaper` (D010) | shell only: `session.json` |
| `vshell theme apply` from a terminal | the helper directly | helper only; the shell adopts it through `MethodTheme`'s `theme.json` watcher |
| `WallpaperCyclingService` | `SessionData.setWallpaper` | shell only: `session.json` |
| Thumbnail sweep | `vshell theme wallpaper-thumbs --all` | the thumbnail cache only; no wallpaper state |

## Decision

**One owner per value, and the two values are not copies of each other.**

- `session.json` holds what each screen shows: `wallpaperPath`, the per-mode and per-monitor maps, and the fill modes. `SessionData` is its only writer, in the shell's own process, and `WallpaperBackground` renders from `SessionData.getMonitorWallpaper` alone.
- `theme-current.json` and a package's `theme.json` hold the image the applied palette was derived from. The helper is their only writer. `~/.config/vshell/theme.json` is the `vgs-shell` target's render of that same value, not a second record of it.

The two legitimately differ: with `wallpaperSource` set to `folder` the user's own wallpaper stays while themes come and go, and under per-monitor or per-mode assignment one screen's image is not the palette's input. Reading either as the other is what was wrong, not their being two fields.

**Mutations are serialized, and dispatch order is execution order.** The helper already takes a process-wide flock for every mutating `theme` subcommand (`theme_mutation_lock`), so two helper processes never interleave their writes. It does not order them: two processes race for that lock, so the older request can win it second and write `theme.json` last. `VGSThemeService` now hands the helper one apply at a time and queues the rest in request order, so the helper's last write is always the last request.

**A failed apply leaves the desktop on the committed wallpaper.** The shell writes `selectedWallpaper` optimistically when an apply starts and rolls it back if the helper refuses, but only while that request still owns the slot, so a late failure cannot revert a newer apply that already moved the desktop on. `session.json` is written only after the helper succeeds, so a refused apply never reaches the screen and nothing needs undoing there.

**Per-monitor assign has no apply window to lose a monitor in.** It is a synchronous `SessionData` write with no helper call (D010): the screen is checked to exist, written, and read back in one frame. A monitor that disconnects afterwards keeps its map entry and shows it again on return; one that disconnects before the write is refused by name.

**A thumbnail temp file belongs to the process building it.** `temp_path` puts that process's pid in the name, and the sweep reclaims a temp file whose pid is gone. The next ordinary sweep therefore clears what a killed one left behind.

## Alternatives Considered

- **Superseding the queued apply, as `RestyleQueue.js` does for restyle previews.** Rejected: `applyFinished` carries success or failure and nothing else, and `ThemeApplyReporter` turns every non-success into an error toast, so a superseded apply has no honest outcome to send. A restyle preview has no reporter and can be dropped silently.
- **Deleting `MethodTheme`'s `theme.json` watcher so the shell has one wallpaper writer.** Rejected: `vshell theme apply` from a terminal writes only helper state, and that watcher is how the shell hears about it. With applies serialized it can no longer disagree with an in-flight pick.
- **Reclaiming a thumbnail temp file by age instead of by owner.** Rejected: the Pillow rung carries no timeout, so no age is safe for every build, while a pid answers exactly.

**Revisit When**: a wallpaper apply gains a step the shell must run while the helper is still working, or a second process outside the shell writes `session.json`.

**Verification**: `scripts/test-theme-apply-queue.js` executes `_runApply`, `_dispatchApply` and `_finishApply`, pinning that one apply reaches the helper at a time, that the rest follow in request order, and that a throwing completion handler still leaves the next apply running. `scripts/test-wallpaper-thumbs.py` pins that pruning keeps a live build's temp file and reclaims one whose process is gone. `scripts/test-switcher-scope.js` pins the per-monitor write, and `scripts/check-vshell-helper.py` the helper's write ordering.

**References**: [D010](D010-single-screen-wallpaper-apply.md), VGS-248, VGS-211, VGS-213, VGS-220.
