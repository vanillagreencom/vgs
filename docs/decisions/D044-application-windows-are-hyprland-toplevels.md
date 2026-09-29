# D044: Application windows are Hyprland toplevels; transient overlays close on an outside click

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: VGS-582

**Refines**: [D032](D032-settings-plugin-and-manifest-settings-convention.md)

**Context**: The Settings window, `vgs.settings` ([D032](D032-settings-plugin-and-manifest-settings-convention.md)), was an unanchored `panel` summon, which the summon host built as a layer surface on the top layer with keyboard focus on demand. A layer surface is not a Hyprland window. Hyprland drew no border on it, did not change a border between active and inactive, did not route the keyboard away from it when the user clicked another window, and did not move, float, tile or close it on the user's keys. The owner reported all four on 2026-09-29. v1 built the same window as a Quickshell `FloatingWindow` (the `v1` branch, `quickshell/vshell/Modals/Settings/SettingsModal.qml`), which behaved as a normal window. VGS had no surface class for an application window: every surface but the bar went through layer-shell.

**Decision**: VGS has two classes of surface, and a plugin picks one through its kind.

| Class | Kinds and surfaces | Behaviour |
|---|---|---|
| Application window | kind `window` | A Hyprland toplevel. Hyprland draws its border and its active and inactive colours, gives it the keyboard when it is focused and takes the keyboard away when another window is, and moves, resizes, floats, tiles and closes it on the user's keys. |
| Transient overlay | the launcher (`overlay`), the notifications and toasts, the requirement notice, widget flyouts (an anchored `panel`, `overlay` or `menu`) and the popups of `qs.Ui` (`Popover`, `Menu`, `Select`, `Tooltip`) | Not a window. It does not tile, move or float. A flyout closes on a click outside it and holds the keyboard only while it is open; the launcher holds the keyboard while it is open. |

- **The kind.** `window` joins `PluginLogic.KINDS` and `SUMMONABLE_KINDS`. Its entry point is an `Item` with `open(payloadJson)` and `close()`, like `panel`. `PluginLogic.summonSurface` decides the surface of every summon: `window` for kind `window` whatever the anchor, `popup` under an anchor, `layer` otherwise. The summon host builds a window as `shell/Hosts/AppWindow.qml`, a Quickshell `FloatingWindow`.
- **Identity.** The window's title is the plugin's manifest `name`. Its class is the shell's one app-id, `org.vgs.shell`, which `shell.qml`'s `//@ pragma AppId` line sets and `HyprlandLayer.APP_WINDOW` holds; `scripts/test-hyprland-layer.js` holds the two equal.
- **Frame.** The window draws no border and no radius of its own, and its background is the `raised` surface level's. Hyprland's decoration is the frame.
- **Size and place.** The Hyprland layer writes one constant core rule after the floating TUIs' rules: `hl.window_rule({ name = "vgs:window", match = { class = "^org\\.vgs\\.shell$" }, float = true, center = true })`. It sets no size: each window asks for the size its instance's `implicitWidth` and `implicitHeight` give, which Hyprland keeps for a floating window. The user tiles the shell's windows by disabling the rule by name after the layer's line, or tiles one window with a float toggle. An anchor passed with a `window` summon is ignored, since the shell cannot place a toplevel; Hyprland maps it on the focused monitor.
- **Close.** A close through Hyprland, such as its close key, is a hide: the host calls the plugin's `close()` and destroys the window.
- **Settings.** `vgs.settings` moves from `panel` to `window`. Escape pops the page, then closes the window while the window has focus. The window stays open behind the floating terminal a manager TUI opens: the terminal is a newer window, which Hyprland focuses and stacks over it.
- **Flyouts.** Every anchored summon and every popup of `qs.Ui` but `Tooltip` takes a focus grab (`PopupWindow.grabFocus`), which is what closes it on an outside click. `Tooltip` takes no grab and closes when the pointer leaves its target. The audit of `shell/` on 2026-09-29 found no flyout without the grab, so no shared component changed.
- **Next.** `vgs.devtools` and `vgs.gallery` are unanchored panels that are application windows by this rule. They move to `window` in a later change; until then each is a layer surface.

**Rationale**:
- A toplevel is the one surface Hyprland treats as a window, so the user's own border, focus, keybinds and rules apply with no VGS code in between. A layer surface would need VGS to imitate each of them, and would still not tile.
- `FloatingWindow` is what v1 used and what Omarchy's dev gallery uses; it is Quickshell's documented toplevel.
- One core rule for one class keeps D028 and D033 whole: the core alone writes window rules, and a plugin writes none.
- A class of VGS's own keeps the rule off other Quickshell applications that share the seat, which carry `org.quickshell`.

## Where VGS differs from Omarchy

Checked against basecamp/omarchy `main` at `b421b1b` (2026-09-29). Omarchy's settings and system menus are walker menus and layer-shell overlays (`omarchy-menu`, `omarchy-keyboard-panel`), and a command that needs a terminal opens in a floating terminal whose class carries the `floating-window` tag (`default/hypr/apps/system.lua`: float, centre, 875 × 600). Its dev gallery is a Quickshell `FloatingWindow` titled `Omarchy shell – dev gallery` (`shell/plugins/dev-gallery/GalleryPanel.qml`), which a rule in `default/hypr/apps/omarchy-shell.lua` matches by the default class `^org.quickshell$` and its title and maximizes. VGS takes the same toplevel and differs in two ways. It sets its own class, since the default class matches every Quickshell application on the seat. It floats and centres through one rule on the class rather than one rule per title, so a new application window needs no new rule.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Keep the layer surface and imitate a window: draw a border from the theme, drop the keyboard on an outside click | Hyprland's own keys still cannot move, float or tile it, and the drawn border cannot follow the user's `general` settings. |
| One app-id per window, such as `org.vgs.settings` | Quickshell 0.3.1's `FloatingWindow` has no app-id property, the xdg app-id of every toplevel is the process's `QGuiApplication::desktopFileName()` (`src/launch/launch.cpp`), and Qt 6.11.2's xdg-shell plugin exposes no per-window app-id. The title names the window instead. |
| A `windowRules` key in the manifest, as the issue proposed | Refused by D028 and D033: only the core writes window rules. One core rule covers every application window. |
| A separate process per application window, for its own app-id | A second shell process breaks the one-process rule (overview.md invariant 1) and loses the core's registry, capabilities and lending. |

**Revisit When**: Quickshell gives a window its own app-id, or a plugin needs an application window Hyprland must not float by default.

**Verification**: `scripts/smoke/rows/windows.sh` reads the Settings window from `hyprctl clients` with the class `org.vgs.shell` and the title Settings, floating and centred on the work area; tiling once `vgs:window` is disabled; its border 4 px wide in the active colour while focused and in the inactive colour while the harness's toplevel helper is focused; moved, tiled, floated, focused and closed by dispatches; and the keyboard reaching the helper alone once it is focused. The gallery, a layer panel, is each reading's control. `scripts/smoke/rows/surfaces.sh` holds the host's rows and a `SummonPopup` copy without the grab that an outside click leaves open; `scripts/smoke/rows/overlays.sh` holds the same for `Popover`, `Menu` and `Select`. `scripts/test-plugin-logic.js` pins `summonSurface`, and `scripts/test-hyprland-layer.js` pins the rule and the pragma.

**References**: [D001](D001-hyprland-only.md), [D005](D005-kinds-are-surfaces-no-dependencies.md), [D018](D018-overlays-are-quickshell-popups.md), [D028](D028-one-generated-hyprland-layer.md), [D032](D032-settings-plugin-and-manifest-settings-convention.md), [D033](D033-floating-tuis-are-core.md), [surfaces.md](../architecture/surfaces.md), [settings-window.md](../architecture/settings-window.md), [hyprland.md](../architecture/hyprland.md)
