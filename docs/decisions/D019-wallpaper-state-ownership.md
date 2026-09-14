# D019: The shell owns the wallpaper on screen; the helper owns the palette's input

[← Decision Index](INDEX.md)

**Date**: 2026-09-14 **Status**: Active **Research**: —

## Summary

Three cancelled patch proposals (VGS-211 serialize wallpaper mutations, VGS-213 give per-monitor assign one verified owner, VGS-220 reap the thumbnail sweep's temp files) all asked the same unanswered question: who owns wallpaper state, in what order is it written, and what happens when two actors touch it at once. This records the answer, and the two places the pipeline did not already hold to it.

## The pipeline

Which surface calls what and writes where is the entry-point table in [wallpaper.md](../architecture/wallpaper.md), which owns current structure. A second copy here would be a second answer to maintain, and the next entry point would have to be added twice.

## Decision

**One owner per value, and the two values are not copies of each other.**

- The desktop's `session.json`, under the state directory, holds what each screen shows: `wallpaperPath`, the per-mode and per-monitor maps, and the fill modes. `SessionData` is its only writer, in the shell's own process, and `WallpaperBackground` renders from `SessionData.getMonitorWallpaper` alone. The greeter profile cache holds a separate file of that name, a snapshot the helper writes and the greeter reads read-only.
- `theme-current.json` and a package's `theme.json` hold the image the applied palette was derived from. The helper is their only writer. `~/.config/vshell/theme.json` is the `vgs-shell` target's render of that same value, not a second record of it.

The two legitimately differ: with `wallpaperSource` set to `folder` the user's own wallpaper stays while themes come and go, and under per-monitor or per-mode assignment one screen's image is not the palette's input. Reading either as the other is what was wrong, not their being two fields.

**Applies are serialized, and dispatch order is execution order — for applies alone.** The helper already takes a process-wide flock for every mutating `theme` subcommand (`theme_mutation_lock`), so two helper processes never interleave their writes. It does not order them: two processes race for that lock, so the older request can win it second and write `theme.json` last. `VGSThemeService` now hands the helper one apply at a time and queues the rest in request order, so between two applies the helper's last write is always the last request.

Within `VGSThemeService` the slot reaches only an apply issued through `_runApply`; every other mutating `theme` subcommand the service launches takes the flock without it. Separately, `MethodTheme._runThemeHelper` issues mutating `theme` subcommands of its own outside the service entirely. Each of those still races an in-flight apply for the lock. Bringing them under the slot was left out because each carries its own completion vocabulary, and a shared slot has to answer what a queued request reports when the surface waiting on it has already moved on.

**A failed apply leaves the desktop on the last apply that succeeded.** `session.json` is written only by a success, and every success commits its own wallpaper, so what it holds is the last apply that landed and a refusal never reaches the screen. The wallpaper slot governs the optimistic `selectedWallpaper` highlight alone: it is written when an apply starts and rolled back on refusal, but only while that request is still the newest pick, so a refusal cannot take the highlight off a later pick queued behind it. Gating the session write on that slot as well was the defect this replaced — with applies queued, an apply could succeed while a later pick already held the slot, and the write it skipped left the desktop on the image before it while the palette came from it.

**Per-monitor assign has no apply window to lose a monitor in.** It is a synchronous `SessionData` write with no helper call (D010): the screen is checked to exist, written, and read back in one frame. A monitor that disconnects afterwards keeps its map entry and shows it again on return; one that disconnects before the write is refused by name.

**A thumbnail temp file belongs to the process building it.** `temp_path` puts that process's pid in the name, and the sweep reclaims a temp file whose pid is gone. The next ordinary sweep therefore clears what a killed one left behind.

## Alternatives Considered

- **Superseding the queued apply, as `RestyleQueue.js` does for restyle previews.** Rejected: `applyFinished` carries success or failure and nothing else, and `ThemeApplyReporter` turns every non-success into an error toast, so a superseded apply has no honest outcome to send. A restyle preview has no reporter and can be dropped silently.
- **Deleting `MethodTheme`'s `theme.json` watcher so the shell has one wallpaper writer.** Rejected: `vshell theme apply` from a terminal writes only helper state, and that watcher is how the shell hears about it. With two applies serialized against each other it can no longer carry the older of two picks.
- **Reclaiming a thumbnail temp file by age instead of by owner.** Rejected: the Pillow rung carries no timeout, so no age is safe for every build, while a pid answers exactly.

**Revisit When**: a mutation outside the slot is seen to overwrite an apply's result and needs to take it; a wallpaper apply gains a step the shell must run while the helper is still working; or a second process outside the shell writes the desktop's `session.json`.

**Verification**: `scripts/test-theme-apply-queue.js` executes `_runApply`, `_dispatchApply` and `_finishApply`, pinning that one apply reaches the helper at a time, that the rest follow in request order whether the one before them succeeded or was refused, that a launch the shell cannot start is answered where it fails so the queue empties rather than parks, that a throwing completion handler still leaves the next apply running, and that an apply which succeeds commits its own wallpaper even with a later pick already queued behind it. `scripts/test-wallpaper-thumbs.py` pins that pruning keeps a live build's temp file and reclaims one whose process is gone. `scripts/test-switcher-scope.js` pins the per-monitor write, and `scripts/check-vshell-helper.py` the helper's write ordering.

**References**: [D010](D010-single-screen-wallpaper-apply.md), VGS-248, VGS-211, VGS-213, VGS-220.
