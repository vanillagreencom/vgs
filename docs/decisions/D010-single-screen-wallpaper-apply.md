# D010: Single-screen wallpaper apply is a verified SessionData write, not a new service method

[← Decision Index](INDEX.md)

**Date**: 2026-08-24
**Status**: Active
**Research**: —

**Context**: The wallpaper switcher's "This monitor" scope (VGS-212) needs an
apply that reaches one screen. The all-monitors path goes through
`VGSThemeService.setWallpaper`, which carries request-correlated reporting and
a failure toast; a per-monitor equivalent could either grow the service a new
correlated method or write `SessionData` directly, the way the dash's
per-monitor buttons already do.

**Decision**: `WallpaperSwitcherModal.applyHere` writes
`SessionData.enablePerMonitorWallpaperFromCurrent()` (when the mode is off) +
`SessionData.setMonitorWallpaper` and builds its own honesty instead of a
service round-trip: the screen is checked to exist first, the write is read
back through `getMonitorWallpaper`, and either miss toasts.

`enablePerMonitorWallpaperFromCurrent` is SessionData's, not the switcher's,
and is the reason the enable is not the bare `setPerMonitorWallpaper(true)` the
dash buttons still use. Flipping the flag alone republishes every retained
`monitorWallpapers` entry (and, under per-mode, the light/dark maps
`syncWallpaperForCurrentMode` refills it from), so picking "This monitor"
changed every OTHER monitor before this apply wrote anything. The seeded enable
writes each connected screen's current picture into all three maps first, then
flips: the mode change is invisible and only the target screen moves. The other
surfaces can adopt it under VGS-213/VGS-214.

**Rationale**:
- SessionData is the one owner of per-monitor assignments; a service method
  would be a second writer wrapping the first for the sake of a reply shape.
  Seeding belongs there for the same reason: it is a write over the maps
  SessionData owns, and every surface that enables the mode needs it.
- The write is synchronous and in-process — there is no helper call whose
  failure needs correlating, so `ThemeApplyReporter`'s machinery has nothing
  to correlate. A read-back answers the only failure it has (a refused write).
- The dash buttons already ship this pair; two surfaces, one pattern.

**Revisit When**: VGS-211 lands its wallpaper-mutation lock (this write is
another mutation and should take the same lock), or a single-screen apply
grows a need the service path has (color extraction, helper-side persistence).

**Verification**: `scripts/test-switcher-scope.js` — executes `applyRoute`,
pins the guard order, the mode flip, the write and the read-back in
`applyHere()`, and pins that `enablePerMonitorWallpaperFromCurrent` seeds all
three maps BEFORE it flips the flag.

**References**: VGS-212, VGS-208 (PR #172), VGS-211.
