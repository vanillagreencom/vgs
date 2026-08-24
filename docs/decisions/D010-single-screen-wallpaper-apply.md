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
`SessionData.setPerMonitorWallpaper(true)` (when off) +
`SessionData.setMonitorWallpaper` — the dash's exact pair — and builds its own
honesty instead of a service round-trip: the screen is checked to exist first,
the write is read back through `getMonitorWallpaper`, and either miss toasts.

**Rationale**:
- SessionData is the one owner of per-monitor assignments; a service method
  would be a second writer wrapping the first for the sake of a reply shape.
- The write is synchronous and in-process — there is no helper call whose
  failure needs correlating, so `ThemeApplyReporter`'s machinery has nothing
  to correlate. A read-back answers the only failure it has (a refused write).
- The dash buttons already ship this pair; two surfaces, one pattern.

**Revisit When**: VGS-211 lands its wallpaper-mutation lock (this write is
another mutation and should take the same lock), or a single-screen apply
grows a need the service path has (color extraction, helper-side persistence).

**Verification**: `scripts/test-switcher-scope.js` — executes `applyRoute` and
pins the guard order, the mode flip, the write and the read-back in
`applyHere()`.

**References**: VGS-212, VGS-208 (PR #172), VGS-211.
