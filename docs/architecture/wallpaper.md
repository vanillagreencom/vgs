# Wallpaper pipeline

Covers: quickshell/vshell/Common/SessionData.qml, quickshell/vshell/Services/VGSThemeService.qml, quickshell/vshell/Services/WallpaperCyclingService.qml, quickshell/vshell/Modules/WallpaperBackground.qml, bin/vshell_wallpaper_thumbs.py

Which value each actor owns, in what order applies reach the helper, and what an interrupted thumbnail sweep leaves behind. Palette derivation and app targets are in [theme.md](theme.md); wallpaper downloads are in [theme-catalog.md](theme-catalog.md).

## Entry points

| Entry point | Calls | Writes |
|---|---|---|
| Wallpaper switcher, Dash Wallpapers, Settings Themes | `VGSThemeService.setWallpaper` → `vshell theme set-wallpaper` | shell: `SessionData`. Helper: package data, and the targets [theme.md](theme.md) names — a pick that keeps the palette moves only the `{wallpaper}` targets, while `--extract` re-derives every role and moves every enabled target |
| Theme switcher, Dash Themes, Settings Themes, Icons tab, catalog download | `VGSThemeService.applyBlueprint` → `vshell theme apply` | shell: `SessionData`. Helper: every enabled target |
| Switcher "This monitor", Dash per-monitor buttons, Settings toggle, `wallpaper` IPC | `SessionData.setWallpaper`, `setMonitorWallpaper` and `setPerMonitorWallpaper` | shell only: `session.json` |
| `vshell theme apply` from a terminal | the helper directly | helper only; the shell adopts it through `MethodTheme`'s `theme.json` watcher |
| `WallpaperCyclingService` | `SessionData.setWallpaper` and `setMonitorWallpaper` | shell only: `session.json` |
| Thumbnail sweep | `vshell theme wallpaper-thumbs --all` | the thumbnail cache only |

## Invariants

- The wallpaper on screen and the palette's input wallpaper are separate values with one writer each, and neither is read as the other. `SessionData` alone writes the desktop's `session.json` under the state directory, which holds `wallpaperPath`, the per-mode and per-monitor maps and the fill modes, and `Modules/WallpaperBackground.qml` renders from `SessionData.getMonitorWallpaper` alone. The greeter profile cache holds a second file of that name, a snapshot `sync_profile_cache` in `bin/vshell_helper.py` writes and `SessionData`'s `greeterSessionFile` reads with `blockWrites`, so the greeter reads it and never writes it. The helper alone writes `theme-current.json` and a package's `theme.json`, which record the image the applied palette was derived from; `~/.config/vshell/theme.json` is the `vgs-shell` target's render of that value rather than a second record of it. The two differ by design where `wallpaperSource` is `folder`, and under per-monitor or per-mode assignment. `MethodTheme`'s `theme.json` watcher is how the shell hears a `vshell theme apply` run from a terminal, which writes no session state.
- An apply issued through `VGSThemeService.applyBlueprint` or `setWallpaper` reaches the helper only while no other such apply is running, so those two run in request order. Every other mutating `theme` subcommand the shell issues is launched through a bare `_run` and still races an in-flight apply for the helper's lock; `MethodTheme`'s `_runThemeHelper`, behind the GTK, Qt and icon-theme settings, runs its own `vshell theme apply` outside the service entirely. `theme_mutation_lock` in `bin/vshell_helper.py` stops two helper processes interleaving their writes but does not order them, so `VGSThemeService._runApply` queues an apply while another is running and `_finishApply` starts the oldest waiting one before it emits its signals. Without that, two picks in quick succession race for the lock, the older one can write `theme.json` last, and the desktop shows one image while the palette on screen was derived from another. `scripts/test-theme-apply-queue.js` checks the ordering and the drain order.
- A refused apply leaves the desktop on the committed wallpaper. `selectedWallpaper` is written optimistically when an apply starts and rolled back on refusal, but only while that request still owns the slot, so a late failure cannot revert a newer apply that already moved the desktop on. `session.json` is written only after the helper succeeds.
- Enabling per-monitor wallpaper mode preserves each screen's current image and disables retained cycling. A per-monitor assign is a synchronous `SessionData` write with no helper call, so it has no window a monitor can vanish in: the screen is checked, written and read back in one frame, a screen that is already gone is refused by name, and one that disconnects later keeps its map entry and shows it again on return. `scripts/test-switcher-scope.js` checks the transition.
- A wallpaper thumbnail is built into a temp file named for the building process, and a sweep reclaims a temp file whose process is gone. `temp_path` and `reclaimable` in `bin/vshell_wallpaper_thumbs.py` own both halves, and `prune_orphans` is the one pruner `build_all` calls. A pid the kernel has reissued reads as live and the file waits for the next sweep, so a build still decoding never loses its temp file. `scripts/test-wallpaper-thumbs.py` checks the keep and the reclaim.

## Decisions

[D010](../decisions/D010-single-screen-wallpaper-apply.md), [D019](../decisions/D019-wallpaper-state-ownership.md).
