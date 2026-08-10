# Scratchpads

A scratchpad is an app parked out of sight that one keybind brings in and puts
away again.

One schema, two backends: Hyprland parks it on a hidden **special workspace**;
Niri, which has none, gives it a **named workspace** of its own (§ Niri).

| Piece | Path |
|-------|------|
| Persisted list | `scratchpads` in `~/.config/vshell/settings.json` (schema v23) |
| Schema, geometry, generation, runtime toggle | `bin/vshell-helper` § Scratchpads |
| Generated config (Hyprland) | `~/.config/hypr/vgs/scratchpads.lua` |
| Generated config (Niri) | `~/.config/niri/vgs/scratchpads.kdl` |
| Shell seam | `quickshell/vshell/Services/ScratchpadService.qml` |
| Settings page | `Modules/Settings/ScratchpadsTab.qml`, `ScratchpadRow.qml` |

Everything from here to § Niri describes the Hyprland backend.

## Why VGS owns this

Presentation is split across two compositor rules that must agree — a workspace
rule and a window rule whose class match decides everything — and a slightly
wrong regex makes the window land on the active workspace with no feedback. VGS
already knows the toplevels, the monitors and their logical sizes, and already
generates compositor config, so it derives the regex and computes the geometry
instead of asking the user to.

## Sizing is a percentage, resolved late

A pad stores `widthPercent`/`heightPercent`, not pixels — pixels are correct on
exactly one display. `sizeMode: "pixels"` remains available for apps with a
hard minimum size.

Percentages resolve against the monitor's **logical** size — `width / scale`,
with the axes swapped on an odd `transform`. Window rules and `hyprctl
dispatch` both speak logical coordinates, so sizing against the reported mode
would make a pad twice the intended size on a 4K panel at scale 2.

Position is a **named anchor plus an offset** (`top-center` + 36px down to
clear the bar), never raw coordinates. The helper resolves anchor + size +
monitor into coordinates and clamps the result onto the monitor: a pad you
cannot see is indistinguishable from a keybind that does nothing.

`vshell scratchpad resolve <id> [monitor]` prints that resolution, so the
geometry is inspectable without applying anything.

## Generated rules are best-effort; the toggle is the mechanism

**Hyprland applies `workspace`/`float`/`size`/`move` exactly once, at map
time.** Any app whose class or title settles after mapping — Electron apps,
1Password, anything with a splash — loses that race permanently, and no rule
expression fixes it. The generated file says so in its own header.

`vshell scratchpad toggle <id>` therefore re-asserts on every reveal, against
the monitor the pad is actually on — also the only place "follow focus" and
multi-monitor can be correct, since neither is knowable at generation time.

**Workspace membership is re-asserted first, and it is the half that matters.**
A window whose class settled after mapping never matched the `workspace` rule
and is sitting on whatever workspace was active at the time; re-asserting only
float/size/move would style it perfectly while leaving it there, and the
reveal would show an empty special workspace. The toggle moves the window onto
the pad's special workspace (`movetoworkspacesilent`, since the reveal happens
a moment later) before placing that workspace on a monitor or revealing it —
the special workspace may not exist at all until something is on it.

The toggle also owns the sequencing:

- **Single press from cold** — launch, *wait for the window*, then reveal.
  Revealing first shows an empty workspace and reads as a dead keybind;
  `on_created_empty` is deliberately unused for the same reason.
- **Placement is checked, not assumed** — a cold-mapped window can create its
  special workspace on whichever monitor had focus, even with a monitor rule
  set. The toggle moves the workspace and re-checks.
- **Focus is restored** — the window that had focus before the reveal gets it
  back on hide, including when the pad lives on another monitor.
- **One transition at a time** — keybind execs are asynchronous, so a double
  press could start two toggles that both see the pad as hidden. Each pad's
  transition is serialized under a lock.

## Identity is the window class, and it claims every instance

A pad's `classRegex` is derived from the app's `StartupWMClass`, which is an
exact class match — so it claims every current and future window of that
application, not just the pad's own. That is by construction:
[D006](../decisions/D006-scratchpad-window-identity.md) records the
measurements and why no per-instance mechanism was adopted instead.

Settings therefore shows how wide a pattern actually is —
`vshell scratchpad match` reports the live windows it claims — and warns when
that is more than one. The derived pattern also carries the lower-case form
(`^(1Password|1password)$`), because apps do not reliably map with the case
they declare (D006 § 4).

To narrow a pad to one instance today: launch it with a class override
(`ghostty --class=my.pad`) and set the pattern to match, or use `titleExclude`.

## Title exclusion is all-or-nothing

`titleExclude` carves a same-class window out of a pad — 1Password's browser
extension prompt shares its class with the main window and must not be
captured. It is applied to **every** rule the pad emits, placement and event
suppression alike, and both rules are built from one shared match so they
cannot drift apart: excluding a window from placement while still suppressing
its activation would leave it half-owned.

An exclusion that does not compile **rejects the whole pad**, exactly as an
uncompilable `classRegex` does — a malformed exclusion is not "no exclusion",
it is an exclusion that silently stops applying.

The exclusion travels with the class everywhere the pad selects a window, not
only into the generated rules: `vshell scratchpad release` takes both, so
removing a pad cannot drag a same-class window the pad never owned onto the
active workspace. Settings passes both explicitly rather than letting the
helper look them up, because it is about to rewrite the settings that lookup
would read.

## A disabled pad does not open

Disabling a pad removes its rules and its keybind, so `vshell scratchpad
toggle` refuses to reveal or preload it — otherwise the enable toggle would
claim a mechanism it does not have. Hiding is still allowed, deliberately: a
pad disabled while on screen would otherwise be stranded visible with no
keybind left to dismiss it.

**Disabling through Settings hides the pad first, then writes** — disabling
through the page removes the keybind in the same operation, so the hide-first
order is what keeps both failure modes recoverable:

| Step that fails | Outcome |
|---|---|
| the hide | the write is skipped, the pad stays enabled, its keybind still works, and the page says why |
| the write or regeneration | the window is already down, and the pad can be re-enabled from the page |

The reverse order has no safe failure: once the bind is gone, a failed hide
leaves a visible window with no way to reach it. `vshell scratchpad hide` is
idempotent for this reason — a pad that is already hidden succeeds without
dispatching, so the call can never accidentally *reveal* one.

**The hide confirms its own outcome**, reading the workspace state back rather
than inferring success from its dispatches — otherwise Settings would take a
reported success as licence to drop the keybind while the window was still up.
The read-back distinguishes three states, not two: `hyprctl -j monitors` can
fail, and "the query did not answer" is not "the pad is down". Only an
explicit `hidden` counts; `unknown` refuses and says so, and Settings leaves
the pad enabled with its keybind intact.

## Presentation is re-asserted as a whole, not additively

The reveal clears fullscreen before applying float or tile. Hyprland keeps the
fullscreen state independently of the window rule, so without this a mapped pad
switched away from fullscreen keeps covering its workspace, and every size/move
dispatch lands on a window whose geometry fullscreen overrides.

## An unanswered status query is not a negative answer

`status.included` has three states: `true`, `false`, and `null` for unknown. A
status query that produced no answer sets `null` rather than leaving the
previous value standing — a stale `true` silences the include banner, whose
entire job is to say "your rules are not wired up". The page says it does not
know instead of picking an answer it has no evidence for.

The same rule covers monitor geometry: a monitor reporting a NaN, infinite,
negative or non-numeric scale degrades to scale 1 with a named warning, rather
than carrying NaN into `int()` and taking the whole geometry path down.

## Removing a pad releases its window

Deleting a pad removes its keybind and every rule pointing at its special
workspace, so a window already mapped there would be left invisible but still
running.

**A release that could not look has not succeeded.** Settings deletes the pad
record only when release reports success, so "the compositor did not answer"
must never be reported as "nothing to release". The window finders return
`None` for an unreadable list and `[]` for a readable empty one, and only the
second authorises deletion.

Settings calls `vshell scratchpad release <id> --class-regex <re>` **before**
deleting the record, which drops fullscreen and moves the window to the active
workspace. Moving is chosen over closing (removing a configuration entry must
not destroy a running program or unsaved work) and over refusing the removal
(a pad the user no longer wants should not be unremovable until they find and
close its window). The regex is passed explicitly so the helper does not read
settings the caller is about to rewrite.

## A configured monitor is an intent, not a guarantee

The runtime toggle resolves the configured output against what is
**connected**. A laptop that has left its dock still carries `DP-1` in the pad
record, and dispatching at a name no output answers to silently does nothing.
When the configured output is absent the pad falls back to the focused one —
the same thing "follow focus" already means — rather than to a dead keybind.
If the monitor list cannot be read at all the configured name is kept, since
relocating a pad on the strength of a failed query would be worse than
trusting the record.

## Two things that look right and are not

**Per-pad animation is a window rule, not the `specialWorkspace` animation
leaf.** That leaf is global — one value for every special workspace on the
system — so emitting it once per pad would mean the last pad silently wins
*and* overwrites the user's own global animation. A window rule is the only
per-pad animation Hyprland has; the workspace slide itself stays global and
VGS does not touch it.

**VGS never edits `hyprland.lua`.** The generated file does nothing until the
config requires it, and this compositor's config is read-only to VGS by
existing convention. Generation reports the one line to add and the Settings
page shows it:

```lua
pcall(require, "vgs.scratchpads")
```

The status check matches any `require` of the module, not the exact `pcall`
spelling, so a user who wrote it plainly is not told to add a duplicate.

## `dismissOnFocusLoss`, and who owns focus

**`Services/CompositorService.qml` is the single owner of compositor focus for
the whole shell.** Nothing else may subscribe to compositor events to learn
about focus, scratchpads included. Quickshell's `ToplevelManager` and
`Hyprland` are process-wide singletons, each holding exactly one connection —
`Hyprland.rawEvent` is documented as "every event that comes in through the
hyprland event socket (socket2)" — and `CompositorService` is where VGS
attaches to them; a second connection is what the one-owner rule forbids.

It publishes one fact, and scratchpads read only that: `activeWorkspaceName` —
the workspace the focused window is on, `""` when unknown. It comes from
`Hyprland.activeToplevel`, which the singleton maintains from the event socket.

**The trigger is the focus transition off a pad's workspace, not "the pad is
visible and unfocused".** Visibility would have to come from a monitor's
special-workspace field, and Quickshell documents `lastIpcObject` as not
updating until the object is fetched again, with `refreshMonitors()`
asynchronous — stale at exactly the instant a pad is being revealed or hidden.
A window's workspace, by contrast, does not change when focus moves, so both
values in the comparison are settled. `ScratchpadService` remembers the last
focused workspace and acts when focus leaves `special:<id>`.

Three things that are load-bearing:

- **`vshell scratchpad hide`, never `toggle`.** A toggle decides direction
  from state read a moment ago; evaluated late it reveals the pad the user
  just dismissed. Hiding a pad that is already hidden is a success, not an
  error — the watcher fires on an event and the user may have got there first.
- **Unknown focus is not "focus is elsewhere".** An empty
  `activeWorkspaceName` means the compositor did not tell us, so nothing is
  dismissed *and* the remembered workspace is left alone — recording the
  unknown would turn the next real change into a phantom transition.
- **A settle delay before acting.** Revealing moves focus twice —
  `focusmonitor` then `focuswindow` — and in between focus is on the target
  monitor but not yet on the pad's window; acting on that instant would
  dismiss the pad the keybind is revealing. The condition is re-read when the
  delay expires, not captured when it started.

Dismissal cannot strand a window: it drives the same helper path as the
keybind, under the same per-pad lock, and hiding restores focus to whatever
held it before the reveal. A **disabled** pad may still be hidden this way,
for the same reason the keybind may hide one.

On **Niri** the whole subsystem is absent, so this setting is absent with it:
`supported` is false, the watcher never runs, `vshell scratchpad hide` refuses
with the same reason as `toggle`, and the Settings page shows the Niri
statement instead of the controls. See § Niri and VGS-83.

## The launch command is argv, not a shell line

A pad's command is exec'd as an **argv array** (`shlex`-parsed, so quoting
still works), never handed to `sh -c`. AGENTS.md § Backend rules requires it,
and on Niri a preloaded pad runs its command at login rather than only when
the keybind is pressed.

A command using shell **syntax** — a pipe, a redirect, `&&`, `;`, a subshell
or a `$…` expansion — is **refused with the reason**, not run either way:
passing `&&` to `execvp` as a literal argument would silently do the wrong
thing, and keeping `sh -c` for exactly the commands where interpretation
matters would keep the rule broken where it counts. The refusal names the
deliberate opt-in:

```
sh -c 'foo && bar'
```

which works, because the classification runs on the **parsed tokens** rather
than the raw string — there the `&&` is inside an argument, not an operator.
The lexer is told to treat punctuation the way a shell does, so `foo; bar` is
caught too rather than hiding the `;` inside `foo;`.

**This is a behaviour change for anyone whose pad command already relied on
shell syntax**: it now refuses with an explanation instead of quietly working.

## Migration

The `scratchpads` list is seeded **empty**, never imported from the
compositor. A pad VGS did not generate is still owned by the user's own
config; adopting it would leave one special workspace with two owners
generating competing rules. Import stays a user action.

## Niri

**A second backend, not a port** (VGS-83). Hyprland remains the reference
implementation; Niri support is additive, with its own generator and its own
toggle.

| | Hyprland | Niri |
|---|---|---|
| Where a pad lives | hidden special workspace | persistent **named** workspace `vgs-<id>` |
| Reveal | `togglespecialworkspace` — overlays the current view | `focus-workspace` — *switches to* it |
| Generated file | `~/.config/hypr/vgs/scratchpads.lua` | `~/.config/niri/vgs/scratchpads.kdl` |
| Include | reported, never written (config is read-only to VGS) | written, with a backup — the existing Niri stance |
| Geometry | VGS resolves anchor + percentage to pixels | niri resolves `proportion` and `relative-to` itself |

**The one difference a user will notice: a pad takes a real slot in the
workspace list and replaces the current view rather than floating over it.**
Niri has nothing that overlays and hides again, so this is the model, not a
shortcut. The Settings page says so on Niri rather than letting it be
discovered as a bug.

**The persisted record is unchanged**, which is what storing an anchor and a
percentage instead of pixels bought. Niri expresses both directly:
`default-column-width { proportion 0.6; }` for size and
`default-floating-position x= y= relative-to="top"` for the anchor, whose
coordinates already run *inward* from the named edge exactly as `offsetX`/
`offsetY` mean them on Hyprland. The percentage stays a percentage all the way
into the compositor, and this backend needs no monitor query to render at all
— the "generated against a nominal display" caveat the Lua file carries does
not arise.

### What Niri cannot express, and how that is said

Reported through an `unsupported` list in the payload, shown on the Settings
page, and — where a control exists — the control is **hidden** rather than
left live and inert:

| Setting | Why |
|---------|-----|
| `animation` | niri's window-open animation is global config, not a window-rule property — the same trap as Hyprland's `specialWorkspace` leaf. The control is hidden on Niri. |
| `dismissOnFocusLoss` | not wired up; the focus owner VGS uses reads the Hyprland event socket. |
| `anchor: center` **with an offset** | niri has no centre `relative-to`. An unoffset centre pad is emitted by *omitting* the position rule, since niri centres new floating windows itself; with an offset the pad is still generated and still centred, and the dropped offset is named. |
| a keybind that cannot be spelled | Keybinds are stored Hyprland-shaped (`SUPER + SHIFT, T`) because that is what the Settings capture writes; they are converted to niri's `Mod+Shift+T`. A key with no keysym name is reported and **no bind is written** — the pad still works through `vshell scratchpad toggle`, and inventing a spelling could shadow a bind the user already has. |

`unsupported` is deliberately separate from `problems`: a pad in `problems`
was **rejected** and generates nothing; a pad in `unsupported` **works**, with
one property dropped. Reporting the second as the first would be as misleading
as not reporting it at all.

### What is rejected outright

Same rule as everywhere else here — reject rather than half-emit — and on Niri
the stakes are higher, because a rule niri refuses to parse takes the **whole
config file** down with it, not just the pad:

- a pattern using anything Rust's regex crate does not implement. It
  guarantees linear time, so it has no backtracking and therefore no
  lookaround, backreferences, conditional or atomic groups, possessive
  quantifiers, inline comment groups, or `\Z` (it spells end-of-text `\z`) —
  all of which Python's `re` accepts. This is a **deny list**: it can prove a
  pattern bad, never prove one good, which is the honest position when there
  is no Niri here to validate against;
- a pattern containing `"#`, which would terminate the KDL raw string early
  and leave a rule that parses as something narrower and quietly stops
  matching.

A rejected pad is rejected **everywhere**, not only in the half that emits
rules: it is also dropped from `spawn-at-startup`, or a pad refused for being
unusable would still launch its app at every login into a session with nowhere
to put it.

### The toggle

Same sequencing as Hyprland, for the same reasons: launch and **wait for the
window** before focusing anything, re-assert workspace membership first for an
app whose app-id settled after mapping, serialize each pad's transition under
the same per-pad lock, restore focus to the window that had it before the
reveal, and confirm the outcome by reading it back rather than trusting that a
dispatch that returned zero did anything.

A disabled pad still refuses to reveal and is still allowed to hide, so
disabling a visible pad cannot strand it.

**On Niri a hide is confirmed against outputs, not just focus.** A pad whose
workspace is still the active one on the output the user is looking at has not
been hidden. But when focus has moved to a *different* output, the pad's own
output goes on showing its active workspace — there is no overlay to pull
away, so that is the whole of what a hide can do, and it reports success while
naming the output the pad is still on; treating it as failure would fail every
hide for every multi-monitor user, and Settings gates on the result. A
workspace list that cannot be read confirms nothing and is reported as such,
never as success.

The reveal origin is **read before the hide and consumed only once it is
confirmed** — the same rule as release. A hide that fails leaves the pad on
screen and the retry still needs somewhere to hand focus back to.

`vshell scratchpad hide [--keep-focus]` reaches both backends with the same
flags, and **where focus lands after a hide is one shared decision**
(`_scratchpad_restore_target`): a keybind hide returns to whatever the pad was
revealed from, a focus-loss dismissal keeps the window the user just moved to,
and an unknown focus — or focus still on the pad itself — falls back to the
origin. Each backend gathers those two values through its own IPC, because it
has no choice, but the rule itself is not duplicated.

`release` moves only the window that is actually **on the pad's workspace** —
matching on class alone would yank a same-class window that was never in the
pad onto the active workspace. The destination is the focused workspace's
`idx`, never its `id`: niri reads a numeric workspace reference as an *index*,
so passing the global id would name a different workspace.
