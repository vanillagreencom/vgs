# D010: Single-screen wallpaper apply is a verified SessionData write, not a new service method

[← Decision Index](INDEX.md)

**Date**: 2026-08-24 **Status**: Active **Research**: —

**Context**: The wallpaper switcher's "This monitor" scope (VGS-212) needs an apply that reaches one screen. The all-monitors path goes through `VGSThemeService.setWallpaper`, which carries request-correlated reporting and a failure toast; a per-monitor equivalent could either grow the service a new correlated method or write `SessionData` directly, the way the dash's per-monitor buttons already do.

**Decision**: `WallpaperSwitcherModal.applyHere` writes `SessionData.setPerMonitorWallpaper(true)` (when the mode is off) + `SessionData.setMonitorWallpaper` and builds its own honesty instead of a service round-trip: the screen is checked to exist first, the write is read back through `getMonitorWallpaper`, and either miss toasts.

**Amendment (VGS-212 review)**: enabling per-monitor mode is seeded, and the seeding lives inside `setPerMonitorWallpaper` rather than in any caller. On the off-to-on edge only, `_seedPerMonitorFromCurrent()` writes what every connected screen currently shows into the four maps that one flag gates — the wallpaper map, both light/dark maps under per-mode, and the fill-mode map — and forces retained per-screen cycling off, before the flag flips. Enabling the mode therefore changes nothing on any screen; the caller's own write afterwards is the only change. The round first shipped this as a second public enable beside the bare setter, which left three unseeded enable sites (the dash button, the Settings toggle, the `wallpaper` IPC handler's `setFor`) and a doc that named the wrong one; folding it into the setter is what removed that class of bug.

Two product calls are recorded here because they are behaviour, not mechanism: the Settings toggle is deliberately seeded too, so turning **Per-Monitor Wallpapers** back on leaves every monitor showing exactly what it shows now instead of restoring months-old assignments; and an enable leaves nothing moving or re-cropped on a screen the caller did not name, which is why retained cycling is forced off and fill modes are seeded from the global fill mode.

**Rationale**:

- SessionData is the one owner of per-monitor assignments; a service method would be a second writer wrapping the first for the sake of a reply shape. Seeding belongs there for the same reason: it is a write over the maps SessionData owns, and every surface that enables the mode needs it.
- The write is synchronous and in-process — there is no helper call whose failure needs correlating, so `ThemeApplyReporter`'s machinery has nothing to correlate. A read-back answers the only failure it has (a refused write).
- One setter, one behaviour: every surface that turns the mode on — switcher, dash button, Settings toggle, IPC — is seeded by construction, and there is no second enable path to keep in step.

**Revisit When**: VGS-211 lands its wallpaper-mutation lock (this write is another mutation and should take the same lock), or a single-screen apply grows a need the service path has (color extraction, helper-side persistence).

**Verification**: `scripts/test-switcher-scope.js` — executes `applyRoute`, pins the guard order, the mode flip, the write and the read-back in `applyHere()`, and pins that `setPerMonitorWallpaper` seeds on the off-to-on edge BEFORE it flips the flag: all four maps (the two mode maps inside the `perModeWallpaper` guard), the cycling force-off, and `_mapWithMonitorValue`'s alias handling. Every pin has a planted mutant seen red.

**References**: VGS-212, VGS-208 (PR #172), VGS-211.
