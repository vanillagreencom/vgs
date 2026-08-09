# D006: Scratchpad window identity stays class-based, made visible rather than replaced

[← Decision Index](INDEX.md)

**Date**: 2026-08-08
**Status**: Active
**Research**: VGS-86
**Applies to**: `bin/vshell-helper` § Scratchpads, `quickshell/vshell/Modules/Settings/ScratchpadsTab.qml`, `docs/architecture/scratchpads.md`

> **Made by an agent, not the owner.** VGS-86 asked which of three identity
> mechanisms to adopt. The measured answer is that none of them covers enough
> ground to be a default, so this record states that, ships the two safe
> improvements, and lists what would reopen it.

## Summary

A scratchpad's `classRegex` is derived from the selected application's
`StartupWMClass`, which is an **exact class match** — it therefore claims every
current and future window of that application, not the one window the pad owns.

We are **not** replacing class matching with a per-instance identity mechanism.
Measurement says no single mechanism is both reliable and general: the strongest
one only works for applications that accept a class-override flag, and VGS
already maintains evidence that a meaningful fraction do not. Instead we made
the breadth of a pattern **visible at configuration time**, and fixed a
derivation bug that made the default silently match nothing for at least one
named application.

## Context — what was actually measured

All figures below are from this workstation's live Hyprland session (15 windows),
read-only via `hyprctl clients -j`. No dispatch, no reload.

### 1. Window class never drifts; window title constantly does

| Field | Windows where the live value differs from the initial value |
|---|---|
| `class` vs `initialClass` | **0 of 15** |
| `title` vs `initialTitle` | **12 of 15** |

Every terminal retitles to its working directory; every browser window retitles
to the page. This is decisive against **title-based narrowing as a default**: the
discriminator would be the one field that is guaranteed to move.

It also refines the subsystem's own map-time-race documentation — the thing that
settles late is the *title*, not the class.

### 2. A launch-time class override works, and narrows to exactly one window

Measured with the new `vshell scratchpad match`, against the live session:

| Pattern | Live windows claimed |
|---|---|
| `^(com\.mitchellh\.ghostty)$` — what Settings derives for Ghostty | **4** |
| `^(com\.ghostty\.scratchpad)$` — a `--class` override at launch | **1** |
| `^(chromium)$` | 2 |

`ghostty --class=com.ghostty.scratchpad` produces exactly that class, alongside
four ordinary Ghostty windows. So the mechanism is real and it does what VGS-86
wants — for this application.

### 3. …but VGS already knows the override is not general

`TERMINAL_SPECS` in `bin/vshell-helper` is a hand-curated table of which
terminals accept an app-id flag and which do not. It exists because the answer
varies per application and cannot be derived:

| Terminal | app-id flag |
|---|---|
| ghostty, kitty, alacritty, wezterm | `--class=` |
| foot, xdg-terminal-exec | `--app-id=` |
| xterm | `-class` |
| **konsole, gnome-terminal** | **none — cannot be overridden** |

Two of nine terminals cannot do it *at all*, and the flag spelling differs three
ways among those that can. That table is pre-existing evidence, gathered for an
unrelated feature, that a class-override mechanism is a per-application registry
and not a general rule.

### 4. The derived default is broken for at least one named application

| Application | `StartupWMClass` declared | Class actually mapped | Derived pattern | Live windows claimed |
|---|---|---|---|---|
| Ghostty | `com.mitchellh.ghostty` | `com.mitchellh.ghostty` | `^(com\.mitchellh\.ghostty)$` | 4 (over-matches) |
| **1Password** | **`1Password`** | **`1password`** | `^(1Password)$` | **0 (matches nothing)** |

1Password ships `StartupWMClass=1Password` and maps as `1password`. The derived
pattern matched *nothing* — a scratchpad that silently never worked, which is a
worse failure than over-matching and was not what VGS-86 was about.

### 5. A sandboxed probe was attempted and is NOT cited

To test Electron and Chromium overrides without touching the live session, a
nested Hyprland was started (the isolation `scripts/qml-smoke.sh` uses) and
candidate apps launched inside it. **Its results are not used here**: in that
sandbox even a *default* Ghostty reported `GTK Application` rather than
`com.mitchellh.ghostty`, contradicting the live session. The sandbox lacks the
desktop-integration state that determines app-id, so it cannot answer identity
questions. It is recorded so nobody repeats it expecting an answer.

**Consequence:** the Electron class-override question is *not* settled. Chromium
app-mode windows in the live session do carry per-app classes
(`chrome-chatgpt.com__-Scratch`), which is suggestive, but that class comes from
Chromium's own `--app=`/profile naming, not from a `--class` flag we tested.

## Decision

1. **Class matching stays the identity mechanism.** It is the only field measured
   to be stable, and it is what Hyprland rules match on.
2. **No per-instance mechanism is adopted as a default.** Launch-time override is
   the strongest candidate and remains available *manually* — a user can set the
   pad's command to `ghostty --class=my.pad` and its pattern to match — but VGS
   will not take ownership of how an application is launched on the strength of a
   mechanism that two of nine known terminals cannot support and that is untested
   on Electron.
3. **Breadth becomes visible instead.** `vshell scratchpad match` reports which
   live windows a pattern claims, and Settings shows "N open windows match this
   pattern — the scratchpad will claim all of them" when N > 1. The over-matching
   default is unchanged in behaviour and no longer invisible.
4. **The derivation is fixed to include the lower-case form.** `^(1Password)$`
   becomes `^(1Password|1password)$`. Plain alternation, not an inline `(?i)`
   flag, because the pattern is handed to Hyprland's matcher and alternation is
   the form already proven in hand-written configs here. It widens matching only
   across case variants of one identity, never to a different application.

### Why not each alternative

| Option | Why not the default |
|---|---|
| **Launch-time identity** (`--class`, app-id override, env marker) | Strongest where supported and *proven* for Ghostty — but the pad would own how the app launches, the flag differs per app, konsole/gnome-terminal have no flag at all, and the Electron case is untested. Adopting it as a default means silently failing for the apps it cannot cover, which VGS-86 explicitly says is worse than not shipping it. |
| **Runtime capture** (remember the first window after the pad's launch) | Works for apps with no override, but the binding does not survive a compositor restart or a shell restart, so the pad would need re-capture at unpredictable times. It also introduces a second source of truth about which window a pad owns, competing with the rules the generator writes — two owners for one decision. |
| **Title-based narrowing by default** | Ruled out by measurement: 12 of 15 live windows had already changed title since mapping. It would be least reliable exactly where it is most needed. `titleExclude` remains available as the opt-in escape hatch it already is. |

## Consequences

- A user configuring a pad gets the same class match as before, plus a warning
  when it currently claims more than one window, and plus a lower-case
  alternative that makes the 1Password-shaped case work at all.
- `titleExclude` remains the supported way to carve out a same-class window, and
  the manual `classRegex` override remains the escape hatch for everything else.
- No new persisted field, therefore **no settings migration** — the schema stays
  at v23.
- `classRegexAuto` is unchanged in meaning: it re-derives from `appId`, now
  producing the case-tolerant form.

## Revisit when

- The Electron class-override question gets a real answer (a faithful test
  environment, or an owner willing to test on the live session). If `--class`
  works on Electron, launch-time identity covers enough of the named app types
  to be worth offering **per-app, opt-in** — not as a default.
- Hyprland gains a per-window handle usable in rules (a PID or token match), which
  would make runtime capture expressible in the generated config rather than only
  at dispatch time.
- Someone hits the over-matching problem with an app that supports neither an
  override nor a stable title discriminator. That is the case none of the three
  mechanisms covers, and it would justify reopening.
