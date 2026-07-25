# Niri as a second supported compositor (plan)

Roadmap for making VGS run on Niri alongside Hyprland. Meant for an agent to
execute later. Phases are ordered so a usable Niri session lands early; the
expensive parsers come last and can be deferred without blocking the rest.

## Current state — read this first, the starting point is not what it looks like

VGS **has no Niri support today**, and never did: it was removed in the first
VGS commit (`feat: seed VGS project`), not degraded over time. What survives is
the *wiring*, not the implementation.

What is missing:
- `Services/NiriService.qml` is a **39-line inert stub**. Every function is a
  no-op returning `{}`, `[]`, `false`, or `""`. Its own comment says
  "Hyprland-only VGS: inert compatibility surface".
- `Services/CompositorService.qml` (142 lines) is hardwired. `isHyprland: true`,
  `isNiri: false` and `compositor: "hyprland"` are **literal constants** — there
  is no detection at all — and every method calls the `Hyprland` API directly.
- `assets/niri.svg` was deleted, so `LauncherButton.qml:66` points at a file
  that no longer exists (inside a dead branch, so it never fires).

What survives, and makes this much cheaper than a from-scratch port:
- `isNiri` is still branched on **212 times across 42 files**; `NiriService.*` is
  still called **118 times across 26 files**. The call sites never stopped
  expecting a real service.
- **All 19 stub functions match upstream's names exactly** (`toggleOverview`,
  `switchToWorkspace`, `getCurrentOutputWorkspaces`, `buildOutputsConfig`, …).
  The stub was written as a signature-compatible shim, so filling it in does not
  require redesigning an API or touching the call sites.
- `Modules/WorkspaceOverlays/NiriOverviewOverlay.qml` (371 lines) and
  `Modules/Settings/DisplayConfig/NiriOutputSettings.qml` (379 lines) are still
  present and intact.
- The `niri*` settings keys are still plumbed through `SettingsData.qml`,
  `SettingsSpec.js` and `settings.default.json`.
- Flags for Mango/Sway/Scroll/Miracle/Labwc are also still branched (105/40/40/
  40/9 refs). Out of scope here, but the same shape.

Reference point: upstream DankMaterialShell's `NiriService.qml` is **1824 lines**
and its `CompositorService.qml` is **1090**. Crucially, upstream's NiriService is
**pure QML over the Niri IPC socket** (`NIRI_SOCKET`) with no dependency on their
Go core — so it can be ported into VGS without dragging in their binary.

## Support tiers — decide these before starting

Not everything can work, so state the target explicitly rather than discovering
it mid-port. Proposed:

| Tier | Features |
|---|---|
| **Full parity** | Bar and all widgets, launcher, dash, control centre, dock, notifications, lock screen, greeter, theming, wallpapers, capture, brightness, idle/lock/screensaver, backend services |
| **Niri-native equivalent** | Workspace switcher (Niri's dynamic workspaces), overview (`NiriOverviewOverlay`), display config (KDL output blocks), keybinds cheatsheet (KDL parse) |
| **Not supported on Niri** | Compositor blur (`BlurService`) — Niri has no blur to drive. The window-rules editor and layout editor are Hyprland-only until Phase 4 |

`AGENTS.md` currently says "Target is Hyprland + Quickshell 0.3.0 only." That
line has to change, and the tier table above should land in the README.

## Test environment — there is a dedicated Niri VM

You do not need to reboot the workstation or build a VM to test this. One
already exists, is running, and is **free to reconfigure or wipe**:

- **libvirt domain `arch-niri-work`** on `qemu:///system` (verified running).
- **Super+8** toggles it — a fullscreen scratchpad wired in
  `~/.config/hypr/config/scratchpads.lua`, launched via
  `~/.local/bin/arch-niri-work-viewer` →
  `libvirt-work-vm-viewer arch-niri-work arch-niri-work-viewer`.
- The scratchpad sets `no_shortcuts_inhibit`, so keystrokes pass through to the
  guest instead of being eaten by the host Hyprland — which is what makes it
  usable for testing Niri keybinds.
- Already logged in, so no console login dance on each boot.

It currently runs the **Noctalia** shell (a Quickshell shell for Niri). That is
**not** something to preserve — remove it entirely. The VM has no other purpose;
treat it as a scratch target for VGS-on-Niri.

Two practical notes for using it:
- Reaching it over a viewer means screenshots and video capture of the guest go
  through the viewer window, so pixel-exact comparisons against the host are not
  meaningful. Test behaviour there, not rendering fidelity.
- The guest needs the VGS clone plus Quickshell 0.3.0. Decide early whether to
  bind-mount the repo in or clone separately — a bind mount keeps the edit/test
  loop tight but means the guest sees the host's `~/.config/vshell` paths.

---

## Phase 0 — groundwork (small, unblocks everything)

1. Restore `assets/niri.svg` (upstream has it, 405 lines).
2. Add real compositor detection to `CompositorService`. Do **not** trust
   `$XDG_CURRENT_DESKTOP` or `$NIRI_SOCKET` alone — a stale systemd user
   environment from a previous session lies. Upstream resolves the owner of the
   actual Wayland socket via `/proc/net/unix` + `/proc/*/fd`, with an env-var
   fallback; port that approach.
3. Turn `isHyprland`/`isNiri`/`compositor`/`compositorDetected` from literals
   into real properties set by detection. **Everything downstream already reads
   these**, so this single change is what "switches on" the 212 existing
   branches — which is exactly why it must come with Phase 1, not before it.

## Phase 1 — the core service and the abstraction

4. Port upstream `NiriService.qml` (1824 lines) over our stub. Keep the stub's
   exact function signatures — they already match. Reconcile drift: upstream has
   moved on since the fork, and our call sites expect the older shape in places.
5. Extend `CompositorService` with Niri paths for every method that currently
   calls `Hyprland` directly: `getScreenScale`, `getFocusedScreen`,
   `filterCurrentWorkspace`, `filterCurrentDisplay`, `refreshMonitors`,
   `anyDisplayOff`, `powerOffMonitors`/`powerOnMonitors`.
   - Do **not** wholesale-copy upstream's 1090-line version. It carries a large
     "connected frame" subsystem VGS does not have, and VGS's version has been
     rewritten around Hyprland. Port method by method.
6. `IdleService` is the happy surprise: 418 lines, **zero** Hyprland references,
   everything already goes through `CompositorService.powerOffMonitors()`. The
   whole idle → lock → screensaver → blank chain needs only step 5 to work.

**Exit criteria for Phase 1:** a Niri session starts the shell, the bar renders,
workspaces switch, the launcher and dash open, the lock screen locks and unlocks.

## Phase 2 — the 25 files that bypass the abstraction

These call `Quickshell.Hyprland` / `Hyprland.*` directly rather than going
through `CompositorService`:

`VGSIPC.qml`, `Widgets/VgsFocusGrab.qml`, `Services/BarWidgetService.qml`,
`Services/BlurService.qml`, `Modules/WallpaperBackground.qml`,
`Modules/Bar/{Bar,BarContent}.qml`,
`Modules/Bar/Widgets/{WorkspaceSwitcher,NotepadButton,KeyboardLayoutName,FocusedApp}.qml`,
`Modules/WorkspaceOverlays/{HyprlandOverview,OverviewWidget}.qml`,
`Modules/Greetd/GreeterContent.qml`, `Modules/Dock/{Dock,DockApps,DockAppButton}.qml`,
`Modules/Plugins/DesktopPluginWrapper.qml`, and others.

Each needs its Hyprland call routed through the abstraction or given a Niri
branch. Two are big enough to plan separately:
- `Modules/Bar/Widgets/WorkspaceSwitcher.qml` — **100 compositor references**.
  Niri's workspaces are dynamic and per-output; this is a genuine rewrite of the
  widget's model, not a branch.
- `Modals/WindowRuleModal.qml` — 69 references.

## Phase 3 — VGS-specific subsystems (the real cost)

Everything below was built **after** the fork, so upstream offers no QML to
port — only a reference implementation in Go to read.

| Subsystem | VGS today | Niri work |
|---|---|---|
| Keybinds | `Services/KeybindsService.qml` (617) + `Modules/Settings/KeybindsTab.qml` (726) + `hypr_binds_json()` in the helper, reading `hyprctl binds -j` | Parse Niri's KDL binds. Upstream spends ~1,300 lines of Go plus ~1,500 of tests on this; ours would be Python in `bin/vshell-helper` |
| Window rules | `Modules/Settings/WindowRulesTab.qml` (1085) | Upstream's Niri parser is 1,048 lines of Go |
| Compositor layout | `Modules/Settings/CompositorLayoutTab.qml` (614) + `apply_hyprland_layout()` | Niri layout is KDL; new writer + a `niri-vgs` theme target beside `hypr-vgs` (upstream's colour template is only 39 lines) |
| Capture | `bin/vshell-capture-screenshot`, `-screenrecording` use `hyprctl clients` for the window picker, including the floating/special-workspace hit-testing fixed in the picker | Niri window enumeration over its IPC. Upstream's Go equivalent is 164 lines |
| Screensaver | `bin/vshell-screensaver` drives fullscreen windows by Hyprland dispatch | Niri spawn/fullscreen equivalent |
| Theme previews | The generator spawns a **nested Hyprland** session (27 refs in the helper) | Hyprland may not be installed on a Niri box. Mitigated: all 79 built-in previews now ship committed, so only user-created themes are affected. Options: require Hyprland as an optional dev dependency, or add a nested-Niri path |
| `bin/` generally | ~100 `hyprctl` invocations across `vshell`, `vshell-helper`, `vshell-capture-*`, `vshell-screensaver` | Audit and branch each |

The Go backend is nearly clean: only **37** Hyprland references, confined to
`internal/services/wlroutput` and `internal/services/gamma`.

## Phase 4 — degrade honestly

- **Blur**: `Services/BlurService.qml` (179 lines, entirely Hyprland) drives
  `hyprctl keyword` rules from `_hyprland_blur_script()` in the helper. Niri has
  no compositor blur. Hide the setting on Niri rather than failing silently.
- Any feature gated off on Niri must grey out with a reason, the same way
  `vshell deps status` handles missing optional tools.

---

## Validation

The host runs Hyprland, so the loop straddles two machines:

1. `qs -c vshell` and `scripts/smoke-surfaces.sh` on Hyprland after **every**
   phase — the top risk of this work is regressing the working compositor.
2. The `arch-niri-work` VM (Super+8, see above) for the actual Niri paths.
3. `scripts/check-settings-migration.js` if any `niri*` settings key changes
   shape.
4. Watch for behaviour that silently depends on `isHyprland` being a constant.
   Phase 0 makes it variable for the first time, so anything that reads it at
   component-construction time may now evaluate before detection completes —
   `compositorDetected` exists for exactly this and should be honoured.

## Sizing, honestly

- Phases 0–2 are the bulk-but-mechanical part: roughly 2,700 lines to port plus
  25 files to reroute. Well-defined, and upstream is a working reference.
- Phase 3 is the project. The keybind and window-rule parsers alone are what
  upstream invested ~4,000 lines of Go in, and VGS would be reimplementing them
  against a different architecture.
- Expect a long tail of "the dock behaves oddly on Niri" bugs after the code is
  nominally complete. This is a multi-week effort, not a weekend port.

A defensible first milestone is **Phases 0–2 only**, shipped as "Niri: bar,
launcher and theming work; keybinds, window rules and layout editing are
Hyprland-only for now." That is genuinely useful, and it is roughly a third of
the total work.
