# Screensaver: native ascii renderer + theme-aspect binding (plan)

High-level roadmap for finishing the screensaver subsystem. Two independent pieces
remain; either can be done on its own. Meant for an agent to execute later.

## Current state (shipped)
- **VGS-native ascii runner** — `bin/vshell-screensaver` (launch/stop/run) + `bin/vshell-transcode-ascii` (image→braille/block art), dispatched via `vshell screensaver …`. Fullscreen `ghostty` per monitor running `tte`, window class `org.vgs.screensaver`. No external screensaver dependency. Branding art at `~/.config/vshell/branding/screensaver.txt`. `ScreensaverService` drives it; Super+Esc toggles via IPC. IdleService/ScreensaverService own all idle gating.
- **Video mode** — already native (`Modules/ScreensaverVideoWindow.qml`, per-screen layer-shell overlay).
- **Settings** — a Screensaver page with an Off/On toggle + type/image/video pickers.

The two items below are the remaining ideal state.

## Piece 1 — native ascii renderer (drop ghostty + `tte`)
Goal: render the ascii saver in a native Quickshell layer-shell surface (like the
video saver), removing the external terminal entirely.

Why native, not `Process`-runs-`tte`: `tte` needs a PTY/terminal; `Process` captures
output and can't display one. So the animation must be reimplemented in QML.

Approach:
- **Helper**: `vshell-transcode-ascii` already produces the char art. Extend it (or a
  sibling) to emit a canonical **high-res char grid + metadata** (dimensions, mode) and
  cache it under `~/.config/vshell/generated/screensaver/<hash>/`.
- **QML**: one fullscreen `WlrLayershell` overlay per screen (mirror `ScreensaverVideoWindow`
  — Overlay layer, exclusive keyboard, dismiss on real key/mouse/motion). Draw the grid
  as monospaced text; each output crops/scales/letterboxes to its own font-cell metrics.
- **Effects**: a small curated set of ported reveal animations (fade / sweep / per-cell
  stagger) driven by QML animations — not the full `tte` library. Start with one good
  effect; add more later.
- **Payoff**: no `ghostty`/`tte` runtime dep, no window-class coupling, native surfaces
  vanish cleanly with the shell (no detached clients).

Risk: the animation won't match `tte`'s polish initially; character rendering fidelity
(braille cell aspect) needs visual iteration.

## Piece 2 — screensaver as a theme aspect
Make the saver theme-defined with a binding policy, consistent with wallpaper/icons.
**Three layers** (do NOT write resolved values into user SettingsData):
- **Theme declares**: `themes/<name>/theme.json` → optional `screensaver` block (type +
  package-relative source + params).
- **User policy**: `settings.json` → `screensaverBinding` = `theme | fixed | off`;
  `screensaverFixed` = a structured content config (not a bare id). Idle *timeout* stays a
  Power/Sleep setting.
- **Applied value**: normalized `screensaver` block written into `~/.config/vshell/theme.json`
  (already watched by MethodTheme), with resolved absolute paths.

`ScreensaverService.effectiveConfig` resolves: off→none · fixed→validated `screensaverFixed`
· theme→applied theme screensaver · theme+missing→built-in default (or none). Fixed settings
are never overwritten by `theme apply`. Snapshot `effectiveConfig` at activation (a theme
switch mid-saver affects the *next* run). Preview takes an explicit candidate config, fully
isolated (no settings/theme/active mutation). Add a "Follow theme / Always X / Off" control
to the Screensaver settings page (the current Off/On toggle omits "Follow theme" until this
resolution exists). Include a settings migration for the new keys.

## Piece 3 — ascii screensaver over the lock (Option B of the idle-flow work)
The shipped idle flow is: idle → **lock** → the lock's screensaver → **blank to black**
→ wake to prompt (`IdleService.lockScreenBlanked` tier + the black overlay in
`Modules/Lock/LockSurface.qml`; the "blank to black" setting is in Power & Sleep).
Because only the lock surface can draw while locked, a screensaver "over the lock"
must be rendered **by the lock**. Today the lock renders a **video** saver
(`Modules/Lock/VideoScreensaver.qml`); the **ascii** saver (ghostty+tte) cannot draw
over the lock. Once the native ascii renderer (Piece 1) exists as a QML surface, host
it inside `LockSurface.qml` as an alternative to the video saver, gated on the
screensaver type, so the ascii art shows over the lock too — then it flows into the
existing blank-to-black endpoint. Settings: add "ascii" as a lock screensaver source
once the renderer lands. **Do this together with Piece 1** (same rendering surface).

## Existing-design bug fixes to fold in (from prior Codex review)
1. Tier ordering: validate/normalize idle thresholds so equal/inverted values can't produce
   undefined order; later transitions idempotently dismiss earlier stages.
2. Inhibitor arrival (`onIdleBlockedChanged`) must actively stop an active saver + cancel
   pending saver/DPMS/lock fades, not just rearm monitors.
3. DPMS is a global bool but outputs are per-output: reapply "off" on hot-plug while
   `desiredDisplaysOff`; keep Hyprland as the multi-GPU abstraction.
4. Video failure: validate the source at apply time + handle runtime media errors
   (fallback/dismiss) rather than showing a black overlay.
5. `ScreensaverVideoWindow` 1s keyboard dead period: dismiss immediately on genuine
   key/mouse-button; only filter stale pointer motion.

## Suggested order
native renderer (helper grid → per-screen QML surface → one effect) → theme-aspect schema →
binding/fixed settings + migration → normalized applied `theme.json` → isolated preview +
activation snapshot → the idle/DPMS bug fixes.
