# Scratchpads

A scratchpad is an app parked on a hidden special workspace that one keybind
slides in and out. Before VGS-62 configuring one meant hand-writing two
compositor rules plus a toggle script, entirely outside VGS.

| Piece | Path |
|-------|------|
| Persisted list | `scratchpads` in `~/.config/vshell/settings.json` (schema v23) |
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

`vshell scratchpad toggle <id>` therefore re-asserts on every reveal, against the
monitor the pad is actually on. That is also the only place "follow focus" and
multi-monitor can be correct, because neither is knowable at generation time.

**Workspace membership is re-asserted first, and it is the half that matters.** A
window whose class settled after mapping never matched the `workspace` rule and
is sitting on whatever workspace was active at the time. Re-asserting only
float/size/move would style that window perfectly while leaving it exactly where
it should not be, and the reveal would show an empty special workspace — which is
the original bug, not a fix for it. The toggle moves the window onto the pad's
special workspace (`movetoworkspacesilent`, since the reveal happens a moment
later) before placing that workspace on a monitor or revealing it. The move comes
first because the special workspace may not exist at all until something is on
it.

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

## Title exclusion is all-or-nothing

`titleExclude` carves a same-class window out of a pad — 1Password's browser
extension prompt shares its class with the main window and must not be captured.
It is applied to **every** rule the pad emits, placement and event suppression
alike. Excluding a window from placement but still suppressing its activation
leaves it half-owned: not in the pad, but stripped of its focus requests anyway,
which is worse than either owning it or leaving it alone. Both rules are built
from one shared match so they cannot drift apart.

An exclusion that does not compile **rejects the whole pad**, exactly as an
uncompilable `classRegex` does. A malformed exclusion is not "no exclusion" — it
is an exclusion the user asked for that silently stops applying, so the pad would
go on to select, focus and move the very windows it existed to keep out.

The exclusion travels with the class everywhere the pad selects a window, not
only into the generated rules: `vshell scratchpad release` takes both, so
removing a pad cannot drag a same-class window the pad never owned onto the
active workspace. Settings passes both explicitly rather than letting the helper
look them up, because it is about to rewrite the settings that lookup would read.

## A disabled pad does not open

Disabling a pad removes its rules and its keybind, so `vshell scratchpad toggle`
refuses to reveal or preload it — otherwise the enable toggle would claim a
mechanism it does not have.

Hiding is still allowed, deliberately: a pad disabled while it was on screen
would otherwise be stranded visible with no keybind left to dismiss it, which is
worse than the problem being solved.

**Disabling through Settings hides the pad first, then writes.** That escape
hatch is not enough on its own, because disabling *through the page* removes the
keybind in the same operation — so the hatch is gone before the user can reach
it. The order matters and both failure modes stay recoverable:

| Step that fails | Outcome |
|---|---|
| the hide | the write is skipped, the pad stays enabled, its keybind still works, and the page says why |
| the write or regeneration | the window is already down, and the pad can be re-enabled from the page |

The reverse order has no safe failure: once the bind is gone, a failed hide
leaves a visible window with no way to reach it. `vshell scratchpad hide` is
idempotent for this reason — a pad that is already hidden succeeds without
dispatching, so the call can never accidentally *reveal* one.

## Presentation is re-asserted as a whole, not additively

The reveal clears fullscreen before applying float or tile. Hyprland keeps the
fullscreen state independently of the window rule, so switching a *mapped* pad
away from fullscreen otherwise left it covering its workspace — and every
size/move dispatch was applied to a window whose geometry fullscreen overrides,
so the setting changed and nothing visible did.

## An unanswered status query is not a negative answer

`status.included` has three states: `true`, `false`, and `null` for unknown. A
status query that produced no answer sets `null` rather than leaving the previous
value standing, because a stale `true` silences the include banner — the one
whose entire job is to say "your rules are not wired up" — on the strength of an
answer that never arrived. The page says it does not know instead of picking one
of the two answers it has no evidence for.

The same rule covers monitor geometry: a monitor reporting a NaN, infinite,
negative or non-numeric scale degrades to scale 1 with a named warning, rather
than carrying NaN into `int()` and taking the whole geometry path down.

## Removing a pad releases its window

Deleting a pad removes its keybind and every rule pointing at its special
workspace, so a window already mapped there would be left unreachable without
`hyprctl` by hand — invisible, but still running.

Settings therefore calls `vshell scratchpad release <id> --class-regex <re>`
**before** deleting the record, which drops fullscreen and moves the window to
the active workspace. Moving is chosen over closing (removing a configuration
entry must not destroy a running program or unsaved work) and over refusing the
removal (a pad the user no longer wants should not be unremovable until they
find and close its window). The regex is passed explicitly so the helper does not
read settings the caller is about to rewrite.

## A configured monitor is an intent, not a guarantee

The runtime toggle resolves the configured output against what is **connected**.
A laptop that has left its dock still carries `DP-1` in the pad record, and
dispatching at a name no output answers to silently does nothing. When the
configured output is absent the pad falls back to the focused one — the same
thing "follow focus" already means — rather than to a dead keybind. If the
monitor list cannot be read at all the configured name is kept, since relocating
a pad on the strength of a failed query would be worse than trusting the record.

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

## `dismissOnFocusLoss`, and who owns focus

**`Services/CompositorService.qml` is the single owner of compositor focus for
the whole shell.** Nothing else may subscribe to compositor events to learn
about focus, scratchpads included.

That ownership predates this feature and is why it needed no new watcher.
Quickshell's `ToplevelManager` and `Hyprland` are process-wide singletons, each
holding exactly one connection — `Hyprland.rawEvent` is documented as "every
event that comes in through the hyprland event socket (socket2)" — and
`CompositorService` is where VGS attaches to them. It already handled
`activewindow`/`activewindowv2`. So the choice was never "add a watcher or
not"; it was "read the existing one, or open a second connection", and a second
connection is what the rule forbids.

It publishes one fact, and scratchpads read only that:
`activeWorkspaceName` — the workspace the focused window is on, `""` when
unknown. It comes from `Hyprland.activeToplevel`, which the singleton maintains
from the event socket.

**The trigger is the focus transition off a pad's workspace, not "the pad is
visible and unfocused".** Visibility would have to come from a monitor's
special-workspace field, and Quickshell documents `lastIpcObject` as not
updating until the object is fetched again, with `refreshMonitors()`
asynchronous — so that field is stale at exactly the instant a pad is being
revealed or hidden, which is the only instant this feature cares about. A
window's workspace, by contrast, does not change when focus moves, so both
values in the comparison are settled. `ScratchpadService` remembers the last
focused workspace and acts when focus leaves `special:<id>`.

Three things that are load-bearing:

- **`vshell scratchpad hide`, never `toggle`.** A toggle decides direction from
  state read a moment ago; evaluated late it reveals the pad the user just
  dismissed. Focus-loss dismissal states the direction it wants. Hiding a pad
  that is already hidden is a success, not an error — the watcher fires on an
  event and the user may have got there first, and that race is ordinary.
- **Unknown focus is not "focus is elsewhere".** An empty `activeWorkspaceName`
  means the compositor did not tell us, so nothing is dismissed *and* the
  remembered workspace is left alone — recording the unknown would erase where
  focus actually was and turn the next real change into a phantom transition.
- **A settle delay before acting.** Revealing moves focus twice — `focusmonitor`
  then `focuswindow` — and in between focus is on the target monitor but not yet
  on the pad's window. Acting on that instant would dismiss the pad the keybind
  is revealing. The condition is re-read when the delay expires, not captured
  when it started.

Dismissal cannot strand a window: it drives the same helper path as the keybind,
under the same per-pad lock, and hiding restores focus to whatever held it
before the reveal. A **disabled** pad may still be hidden this way, for the same
reason the keybind may hide one — the alternative is a pad stranded on screen.

On **Niri** the whole subsystem is absent, so this setting is absent with it:
`supported` is false, the watcher never runs, `vshell scratchpad hide` refuses
with the same reason as `toggle`, and the Settings page shows the Niri statement
instead of the controls. See § Niri and VGS-83.

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
