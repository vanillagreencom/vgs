# Scratchpads

A scratchpad is an app parked on a hidden special workspace that one keybind
slides in and out. Before VGS-62 configuring one meant hand-writing two
compositor rules plus a toggle script, entirely outside VGS.

| Piece | Path |
|-------|------|
| Persisted list | `scratchpads` in `~/.config/vshell/settings.json` (schema v22) |
| Schema, geometry, generation, runtime toggle | `bin/vshell-helper` § Scratchpads |
| Generated compositor config | `~/.config/hypr/vgs/scratchpads.lua` |
| Shell seam | `quickshell/vshell/Services/ScratchpadService.qml` |
| Settings page | `Modules/Settings/ScratchpadsTab.qml`, `ScratchpadRow.qml` |

## Why VGS owns this

Presentation is split across two rules that must agree — a workspace rule and a
window rule whose class match decides everything. A slightly wrong regex makes
the window land on the active workspace instead, with no feedback. VGS already
knows the toplevels, the monitors and their logical sizes, and already generates
compositor config, so it can derive the regex and compute the geometry instead
of asking the user to.

## Sizing is a percentage, resolved late

A pad stores `widthPercent`/`heightPercent`, not pixels. Pixels are correct on
exactly one display; a percentage is what users actually mean. `sizeMode:
"pixels"` remains available for apps with a hard minimum size.

Percentages resolve against the monitor's **logical** size — `width / scale`,
with the axes swapped on an odd `transform`. Window rules and `hyprctl dispatch`
both speak logical coordinates, so sizing against the reported mode would make a
pad twice the intended size on a 4K panel at scale 2.

Position is a **named anchor plus an offset** (`top-center` + 36px down to clear
the bar), never raw coordinates. The helper resolves anchor + size + monitor into
coordinates and clamps the result onto the monitor: a pad you cannot see is
indistinguishable from a keybind that does nothing.

`vshell scratchpad resolve <id> [monitor]` prints that resolution, so the
geometry is inspectable without applying anything.

## Generated rules are best-effort; the toggle is the mechanism

**Hyprland applies `workspace`/`float`/`size`/`move` exactly once, at map time.**
Any app whose class or title settles after mapping — Electron apps, 1Password,
anything with a splash — loses that race permanently, and no rule expression
fixes it. The generated file says so in its own header.

`vshell scratchpad toggle <id>` therefore **re-asserts presentation on every
reveal**, against the monitor the pad is actually on. That is also the only place
"follow focus" and multi-monitor can be correct, because neither is knowable at
generation time.

The toggle also owns the sequencing:

- **Single press from cold** — if the app is not running, launch it, *wait for
  its window*, and only then reveal. Revealing first shows an empty workspace and
  reads as a dead keybind, which is why users press it two or three times.
  `on_created_empty` is deliberately unused for exactly this reason.
- **Placement is checked, not assumed** — a cold-mapped window can create its
  special workspace on whichever monitor had focus, even with a monitor rule set.
  The toggle moves the workspace and re-checks, rather than trusting the rule.
- **Focus is restored** — the window that had focus before the reveal gets it
  back on hide, including when the pad lives on another monitor.
- **One transition at a time** — keybind execs are asynchronous, so a double
  press could otherwise start two toggles that both see the pad as hidden. Each
  pad's transition is serialized under a lock.

## Two things that look right and are not

**Per-pad animation is a window rule, not the `specialWorkspace` animation
leaf.** That leaf is global — one value for every special workspace on the
system. Emitting it once per pad would mean the last pad silently wins *and*
overwrites the user's own global animation. A window rule is the only per-pad
animation Hyprland has, so that is what the setting controls; the workspace slide
itself stays global and VGS does not touch it.

**VGS never edits `hyprland.lua`.** The generated file does nothing until the
config requires it, and this compositor's config is read-only to VGS by existing
convention. Generation reports the one line to add and the Settings page shows
it:

```lua
pcall(require, "vgs.scratchpads")
```

The status check matches any `require` of the module, not the exact `pcall`
spelling, so a user who wrote it plainly is not told to add a duplicate.

## Migration

The `scratchpads` list is seeded **empty**, never imported from the compositor. A
pad VGS did not generate is still owned by the user's own config; adopting it
would leave one special workspace with two owners generating competing rules.
Import stays a user action.

## Niri

**Not implemented — a deliberate split, not an oversight.** Hyprland is the
reference implementation. Niri has no special workspaces at all: the equivalent
is a named workspace plus window rules and a `focus-or-toggle` bind, which is a
different data model and a different generator, not a translation of this one.

`vshell scratchpad apply|toggle|preload` refuses on Niri with that reason rather
than writing Hyprland config into a session that will never read it, and the
Settings page shows the same statement instead of a page of dead controls.
